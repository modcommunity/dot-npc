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

	sight_checks += 1

	var to_target := cand.position - npc.position()
	var distance := to_target.length()

	if distance <= 0.0001:
		return true

	# Hearing first: it is a single compare and it needs no raycast, so an NPC that
	# can hear something never pays for the cone or the cast.
	if distance <= minf(npc.def.hearing_range, cand.loudness):
		return true

	if distance > npc.def.sight_range:
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

	var query := PhysicsRayQueryParameters3D.create(
		npc.position(), cand.position, occlusion_mask
	)
	# Excluded by RID, which is what `exclude` takes — an instance id is an int and
	# `Array[RID]` refuses it. A body that is not a CollisionObject3D has no RID to
	# exclude and needs none: it is not in the physics world to be hit by the cast.
	if npc.node is CollisionObject3D:
		query.exclude = [(npc.node as CollisionObject3D).get_rid()]

	return world.direct_space_state.intersect_ray(query).is_empty()


## Picks or keeps a target for [param npc]. Returns its id, or empty for none.
##
## [param now] is simulated seconds, never a wall clock: an NPC's grace period must be
## the same on a server that stalls for a second as on one that does not.
func update_target(npc: DotNpcInstance, candidates: Array, now: float,
		candidate_cap: int = 32) -> StringName:
	if npc == null or not npc.is_alive():
		return &""

	var best: Candidate = null
	var best_distance := INF
	var committed: Candidate = null
	var committed_distance := INF
	var considered := 0

	for entry in candidates:
		if considered >= candidate_cap:
			break

		var cand := entry as Candidate

		if cand == null:
			continue

		considered += 1

		if not perceives(npc, cand):
			continue

		var d := npc.position().distance_to(cand.position)

		if cand.id == npc.target_id:
			committed = cand
			committed_distance = d

		if d < best_distance:
			best_distance = d
			best = cand

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
