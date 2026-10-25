class_name DotNpcSenses
extends RefCounted

## What an NPC can perceive, and what it has committed to chasing.
##
## [b]Commitment with hysteresis is the whole point of this class.[/b] "Nearest
## visible enemy" recomputed every tick is the classic broken NPC: two players a
## metre apart make it turn back and forth for ever, and one who steps behind a pillar
## makes it forget instantly and walk away mid-swing. So a target is acquired at one
## threshold and dropped at a weaker one, and dropping is delayed by a grace period
## measured from the last sighting rather than from acquisition.
##
## Candidates are supplied by the game as plain data — an id, a position, a faction
## and a loudness — so this never mentions dot-combat, dot-net or a player class.

## A perception candidate. Built by the game, not by this addon.
class Candidate:
	extends RefCounted

	var id: StringName = &""
	var position: Vector3 = Vector3.ZERO
	var faction: StringName = &""

	## How loud it is right now, in metres of audibility. 0 is silent.
	##
	## A radius rather than a decibel level, because that is the number a game already
	## has: a sprinting player is heard further than a crouching one.
	var loudness: float = 0.0

	func _init(p_id: StringName = &"", p_pos: Vector3 = Vector3.ZERO,
			p_faction: StringName = &"", p_loudness: float = 0.0) -> void:
		id = p_id
		position = p_pos
		faction = p_faction
		loudness = p_loudness


## How much closer a rival must be before an NPC will switch to it. 1.0 = no stickiness.
##
## The acquire/drop asymmetry. At 0.6 a new candidate must be 40% nearer than the
## committed one, which is far enough that two players standing together cannot
## make it oscillate.
var switch_ratio: float = 0.6

## Seconds an NPC keeps chasing a target it can no longer perceive.
##
## Measured from the last sighting. Without it, a doorway is a perfect escape and the
## NPC turns away while still in swinging range.
var commitment_grace: float = 3.0

## Set false to skip line-of-sight raycasts wholesale, whatever the definition says.
var line_of_sight_enabled: bool = true

## Physics collision mask used for the occlusion raycast.
var occlusion_mask: int = 1

var sight_checks: int = 0
var los_casts: int = 0


## Whether [param npc] can perceive [param cand] right now, ignoring commitment.
##
## Sight is range + cone + optional occlusion; hearing is range only and ignores
## facing, which is what stops an NPC having a perfect blind spot behind it.
func perceives(npc: DotNpcInstance, cand: Candidate) -> bool:
	if npc == null or cand == null or not npc.is_alive() or npc.def == null:
		return false

	if cand.faction == npc.def.faction:
		return false

	return _perceives_at(npc, cand, cand.position - npc.position())


## [method perceives] past the faction test, with the offset already taken.
func _perceives_at(npc: DotNpcInstance, cand: Candidate, to_target: Vector3) -> bool:
	sight_checks += 1

	var distance := to_target.length()

	if distance <= 0.0001:
		return true

	# Hearing first: one compare and no raycast.
	if distance <= minf(npc.def.hearing_range, cand.loudness):
		return true

	if distance > npc.def.sight_range * maxf(npc.sight_scale, 0.0):
		return false

	if npc.def.sight_half_angle_deg < 180.0:
		var angle := npc.facing().angle_to(to_target / distance)
		if angle > npc.def.sight_half_angle():
			return false

	if npc.def.require_line_of_sight and line_of_sight_enabled:
		return _has_line_of_sight(npc, cand)

	return true


func _has_line_of_sight(npc: DotNpcInstance, cand: Candidate) -> bool:
	if not (npc.node is Node3D):
		# [b]A 2D NPC has no 3D physics world to cast through, and answering "blocked"
		# would blind it permanently.[/b] A 2D game that wants occlusion sets
		# `line_of_sight` false on the definition and does the test itself, which is what
		# the flag is for; what must not happen is this returning false and every NPC in
		# the game standing still with nothing in the log.
		return true

	var world := (npc.node as Node3D).get_world_3d()

	if world == null:
		# No physics world means no walls to be blocked by. Returning false here would
		# blind every NPC in a scene that has not been added to a viewport yet, which
		# is exactly the state a spawner is in for one frame after it spawns one.
		return true

	los_casts += 1

	# From the eyes, not the feet: see [member DotNpcDef.eye_height].
	var query := PhysicsRayQueryParameters3D.create(
		npc.position() + Vector3.UP * npc.def.eye_height, cand.position, occlusion_mask
	)
	# Excluded by RID, which is what `exclude` takes — an instance id is an int and
	# `Array[RID]` refuses it. A body that is not a CollisionObject3D has no RID to
	# exclude and needs none: it is not in the physics world to be hit by the cast.
	if npc.node is CollisionObject3D:
		query.exclude = [(npc.node as CollisionObject3D).get_rid()]

	return world.direct_space_state.intersect_ray(query).is_empty()


## Picks or keeps a target for [param npc]. Returns its id, or empty for none.
##
## [param now] is simulated seconds, never a wall clock. Candidates within reach (sight or
## hearing) are tested nearest first, at most [param candidate_cap], plus the committed one.
func update_target(npc: DotNpcInstance, candidates: Array, now: float,
		candidate_cap: int = 32) -> StringName:
	if npc == null or not npc.is_alive() or npc.def == null:
		return &""

	var packed := Packed.new()
	packed.fill(candidates)
	var held := packed.index_of(npc.target_id)
	var order := rank(npc.position(), reach_of(npc), npc.def.hearing_range,
		packed.faction_of(npc.def.faction), packed, candidate_cap)
	return decide(npc, candidates, order, held, now)


## Candidates as packed arrays, built once a tick on the main thread: what [method rank] reads,
## on any thread.
class Packed:
	extends RefCounted

	var positions := PackedVector3Array()
	var loudness := PackedFloat64Array()
	var factions := PackedInt32Array()
	var _faction_ids: Dictionary = {}
	var _index: Dictionary = {}

	func fill(candidates: Array) -> void:
		var n := candidates.size()
		positions.resize(n)
		loudness.resize(n)
		factions.resize(n)
		_faction_ids.clear()
		_index.clear()

		for i in n:
			var cand := candidates[i] as Candidate

			if cand == null:
				factions[i] = -2
				loudness[i] = 0.0
				continue

			positions[i] = cand.position
			loudness[i] = cand.loudness
			factions[i] = _faction_ids.get_or_add(cand.faction, _faction_ids.size())
			if not _index.has(cand.id):
				_index[cand.id] = i

	## The faction's number in [member factions], or -1 when no candidate has it.
	func faction_of(faction: StringName) -> int:
		return _faction_ids.get(faction, -1)

	## The first candidate with [param id], or -1.
	func index_of(id: StringName) -> int:
		return -1 if id == &"" else int(_index.get(id, -1))


## How far [param npc] sees, after its [member DotNpcInstance.sight_scale].
static func reach_of(npc: DotNpcInstance) -> float:
	return npc.def.sight_range * maxf(npc.sight_scale, 0.0)


## The candidates an NPC at [param here] could perceive by range alone, nearest first, at most
## [param cap]: [method rank_many] for one NPC.
static func rank(here: Vector3, sight: float, hearing: float, own_faction: int,
		packed: Packed, cap: int) -> PackedInt32Array:
	return rank_many(0, 1, PackedVector3Array([here]), PackedFloat64Array([sight]),
		PackedFloat64Array([hearing]), PackedInt32Array([own_faction]),
		packed.positions, packed.loudness, packed.factions, cap)[0]


## [method rank] for NPCs [param from] to [param to] (exclusive) of the per-NPC arrays, one
## [PackedInt32Array] each. Pure over packed data, so it may run on a worker thread.
static func rank_many(from: int, to: int, here: PackedVector3Array, sight: PackedFloat64Array,
		hearing: PackedFloat64Array, own: PackedInt32Array, positions: PackedVector3Array,
		loudness: PackedFloat64Array, factions: PackedInt32Array, cap: int) -> Array:
	var out: Array = []
	var count := positions.size()
	var keep := maxi(cap, 1)

	for j in range(from, to):
		var at := here[j]
		var seen := sight[j]
		var heard := hearing[j]
		var mine := own[j]
		var keys := PackedInt64Array()

		for i in count:
			var f := factions[i]

			if f == mine or f == -2:
				continue

			var d2 := at.distance_squared_to(positions[i])
			var reach := maxf(seen, minf(heard, loudness[i]))

			# Out of reach is never perceived, so it never takes a slot of the cap.
			if d2 > reach * reach and d2 > 0.00000001:
				continue

			# Distance in 1/1024 m^2 above the index: one native sort is the nearest-first order.
			keys.append((int(d2 * 1024.0) << 20) | i)

		keys.sort()
		var order := PackedInt32Array()
		order.resize(mini(keys.size(), keep))

		for r in order.size():
			order[r] = keys[r] & 0xFFFFF

		out.append(order)

	return out


## Commits [param npc] given [param order] from [method rank] over [param candidates]:
## tests in order until one is perceived (the nearest, so nothing further can be better), and
## the committed candidate ([param held], its index or -1) too. Main thread: it casts rays.
func decide(npc: DotNpcInstance, candidates: Array, order: PackedInt32Array, held: int,
		now: float) -> StringName:
	if npc == null or not npc.is_alive() or npc.def == null:
		return &""

	var here := npc.position()
	var best: Candidate = null
	var best_distance := INF
	var committed: Candidate = null
	var committed_distance := INF
	var held_tested := false

	for index in order:
		var cand := candidates[index] as Candidate

		if index == held:
			held_tested = true

		if _perceives_at(npc, cand, cand.position - here):
			best = cand
			best_distance = here.distance_to(cand.position)

			if index == held:
				committed = cand
				committed_distance = best_distance
			break

	if not held_tested and held >= 0 and held < candidates.size():
		var cand := candidates[held] as Candidate

		if cand != null and cand.id == npc.target_id and cand.faction != npc.def.faction \
				and _perceives_at(npc, cand, cand.position - here):
			committed = cand
			committed_distance = here.distance_to(cand.position)

	if committed != null:
		npc.target_seen_at = now
		npc.engaged_at = now

		# The stickiness. A rival has to beat the committed target by the ratio, not
		# merely tie with it, or two candidates at the same range flip every tick.
		if best != null and best.id != committed.id \
				and best_distance < committed_distance * switch_ratio:
			npc.target_id = best.id
			npc.target_since = now
			return npc.target_id

		return npc.target_id

	if npc.has_target():
		# Committed target not perceived this pass. Keep chasing until the grace
		# expires — but a perceived rival ends it immediately, because an NPC that
		# ignored the player hitting it to chase one that left is worse than either.
		if best != null:
			# A different rival, so the commitment is new — and a reaction time has to
			# start again. Guarded on the id rather than assigned unconditionally,
			# because re-perceiving the SAME target after a gap is not a new commitment
			# and restarting the clock there would be an NPC that never finishes reacting
			# to somebody who keeps stepping behind a pillar.
			if npc.target_id != best.id:
				npc.target_since = now

			npc.target_id = best.id
			npc.target_seen_at = now
			npc.engaged_at = now
			return npc.target_id

		if now - npc.target_seen_at < commitment_grace:
			return npc.target_id

		npc.target_id = &""
		return &""

	if best != null:
		# The first commitment: nothing was held, and something is now.
		npc.target_id = best.id
		npc.target_seen_at = now
		npc.engaged_at = now
		npc.target_since = now

	return npc.target_id


func describe() -> Dictionary:
	return {
		"switch_ratio": switch_ratio,
		"grace": commitment_grace,
		"sight_checks": sight_checks,
		"los_casts": los_casts,
	}
