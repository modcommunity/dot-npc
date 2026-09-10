@tool
class_name DotNpcSpawner
extends Node

## Spawns, senses, thinks, hurts and reclaims. The node a game with NPCs adds.
##
## [b]Server-authoritative, and NPCs are not predicted.[/b] The same decision
## [DotPropSpawner] makes and for a stronger reason: an NPC's position is the output of
## a pathfinder over a graph, a steering pass and — for a rigid-body NPC — a physics
## solver, none of which is reproducible across machines. Two runs of the same horde
## diverge within a second, so a predicted NPC is a corrected NPC and the correction is
## constant. The server owns every NPC; a client draws what it is told, interpolated a
## few tens of milliseconds behind. See [DotNpcNetSync] for what crosses the wire.
##
## [b]It does not own the tick.[/b] [method tick] is called by the game's simulation at
## the game's fixed rate, exactly as [DotMatch] and [DotTimerManager] are, so an NPC's
## speed is not a function of the frame rate and a headless suite can step it a
## thousand times in no time at all.
##
## [codeblock]
## var npcs := DotNpcSpawner.new()
## npcs.catalogue = catalogue
## npcs.limits = DotNpcLimits.new()
## npcs.world_ref = DotNodeRef.of_path(^"../World")
## npcs.authoritative = true
## add_child(npcs)
##
## # Every simulated tick:
## npcs.set_candidates(players_as_candidates())
## npcs.tick(delta)
## [/codeblock]

const CHANNEL := "npc"

## An NPC entered the world.
signal spawned(npc: DotNpcInstance)

## One left it. [param reason] is one of the REASON_* constants.
signal removed(npc: DotNpcInstance, reason: StringName)

## An NPC took damage. Fired after the health has already been reduced.
signal damaged(npc: DotNpcInstance, amount: float, by: StringName)

## Its health reached zero. Fired before [signal removed], while the node still exists.
##
## [b]Separate from [signal removed] on purpose.[/b] Dying and being reclaimed are not
## the same event: one scores, drops loot and plays a sound, and the other is a
## director tidying up something nobody could see. A game that had only `removed` would
## either award a kill for the tidy-up or have to guess.
signal died(npc: DotNpcInstance, by: StringName)

## An NPC committed to something new, or let go. [param target] may be empty.
signal target_changed(npc: DotNpcInstance, target: StringName)

## A spawn was refused, and why.
signal refused(owner_id: StringName, npc_id: StringName, reason: String)

const REASON_KILLED := &"killed"
const REASON_RECLAIMED := &"reclaimed"
const REASON_LEFT := &"left"
const REASON_CLEANUP := &"cleanup"
const REASON_ADMIN := &"admin"

@export_group("Content")

@export var catalogue: DotNpcCatalogue = null

@export var limits: DotNpcLimits = null

@export_group("Wiring")

## Where spawned NPCs are added. Defaults to this node.
@export var world_ref: DotNodeRef = null

@export_group("Role")

## Whether this spawner may actually create NPCs. False on a client.
##
## Every mutating method refuses on a non-authoritative spawner before it checks
## anything else, for [DotPropSpawner]'s reason: a client that could spawn is a
## modified client that fills the world.
@export var authoritative: bool = false

@export_group("Navigation")

## Remove the corners the grid put in a path that the world does not have.
##
## On. A graph on a two-metre grid can only turn in eight directions, so an NPC
## crossing an open room walks a visible staircase — and it is the first thing anybody
## watching one notices. Off is for a game whose own follower smooths, and for
## measuring what smoothing is worth.
@export var smooth_paths: bool = true

## Walk toward an unreachable goal rather than standing still.
##
## On, for the reason [method DotNpcBrain.steer_along_path] falls back to steering
## straight: an NPC that stops dead when the generator missed a corner is a bug nobody
## can see the cause of. Detour reports the same thing as a partial result.
@export var allow_partial_paths: bool = true

@export_group("Perception")

## Physics collision mask the line-of-sight raycast uses.
@export_flags_3d_physics var occlusion_mask: int = 1

## Navigation for the map currently loaded, or null for a game that paths its own way.
var nav: DotNpcNavGraph = null

## def id -> DotNpcNavFilter, built on first use. See [method _filter_for].
var _nav_filters: Dictionary = {}

## Shared perception. One object, because its tuning is the world's rather than an
## NPC's — two NPCs that gave up on a target at different ranges would be a game
## design decision, and it belongs in the definition, not in a second senses object.
var senses: DotNpcSenses = null

## How far a goal may move before a path is recomputed, in metres.
var repath_drift: float = 2.5

## Seconds between forced repaths even when the goal has not moved.
var repath_interval: float = 1.5

## Instance id -> DotNpcInstance.
var _npcs: Dictionary = {}

## Kind id -> how many of that kind are alive. Kept rather than counted, because the
## per-kind cap is checked on every spawn and a director spawning a wave asks it
## dozens of times in one tick.
var _by_kind: Dictionary = {}

## Owner id -> Array[int] of instance ids.
var _by_owner: Dictionary = {}

## Owner id -> simulated seconds when they last spawned one.
var _last_spawn: Dictionary = {}

## What the NPCs can perceive this tick. Rebuilt by the host; never cached across
## ticks, because a candidate list held across ticks is a list of where people were.
var _candidates: Array = []

## Candidate id -> position, for [method candidate_position]. Rebuilt with the list.
var _candidate_positions: Dictionary = {}

## Simulated seconds. Advanced by [method tick], never a wall clock.
var _now: float = 0.0

## Whole simulated ticks. What perception staggering is keyed on.
var _ticks: int = 0

var _world: Node = null

var spawn_count: int = 0
var refusal_count: int = 0
var kill_count: int = 0
var reclaim_count: int = 0


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	if limits == null:
		limits = DotNpcLimits.new()

	if senses == null:
		senses = DotNpcSenses.new()

	senses.occlusion_mask = occlusion_mask

	var valid := limits.validate()

	if not valid.ok:
		DotLog.warn(CHANNEL, "npc limits are not usable", {"why": valid.error.message})


# --- Navigation ---------------------------------------------------------------

## Adopts navigation for the map now loaded. Null clears it.
##
## Called on every map change, because navigation is generated per map and one held
## across a change is a graph of a level nobody is standing in — an NPC pathing over it
## walks through walls, which is far worse than one with no navigation at all.
func set_nav_data(data: DotNpcNavData) -> DotResult:
	if data == null:
		nav = null
		return DotResult.success(null)

	var graph := DotNpcNavGraph.new()
	var built := graph.rebuild(data)

	if not built.ok:
		nav = null
		return built.wrap("Navigation for this map was refused.")

	nav = graph

	return DotResult.success(nav)


func has_nav() -> bool:
	return nav != null and nav.is_ready()


## The next point [param npc] should walk toward to reach [param goal].
##
## Called by [DotNpcBrain.steer_along_path]. Recomputes the path when it has drifted or
## expired, and returns the goal itself when there is no navigation — which is the
## documented fallback, not a failure.
func path_toward(npc: DotNpcInstance, path: DotNpcPath, goal: Vector3) -> Vector3:
	if not has_nav() or npc == null or not npc.is_alive() or path == null:
		return goal

	if path.needs_repath(_now, goal, repath_interval, repath_drift):
		# The filter is set per search rather than held on the graph, because one
		# graph serves every NPC on the map and they do not agree about it: the thing
		# that cannot crouch and the thing that can are asking different questions of
		# the same points.
		nav.filter = _filter_for(npc.def)

		var found := (
			nav.find_smooth_path(
				npc.position(), goal, limits.spawn_snap_radius, allow_partial_paths
			) if smooth_paths
			else nav.find_path(
				npc.position(), goal, limits.spawn_snap_radius, allow_partial_paths
			)
		)

		path.set_points(found, _now, goal)
		path.partial = nav.last_partial

	if path.is_empty():
		return goal

	return path.advance(npc.position(), goal)


## The navigation filter for one kind of NPC, built once and kept.
##
## Cached because a filter is rebuilt on every repath otherwise — a few hundred
## allocations a second on a busy server for an object whose contents never change
## once the catalogue is loaded.
func _filter_for(def: DotNpcDef) -> DotNpcNavFilter:
	if def == null or def.nav_exclude_flags == 0:
		return null

	if _nav_filters.has(def.id):
		return _nav_filters[def.id]

	var filter := DotNpcNavFilter.new()
	filter.exclude_flags = def.nav_exclude_flags
	_nav_filters[def.id] = filter

	return filter


# --- Perception input ---------------------------------------------------------

## What the NPCs may perceive this tick. Called by the host before [method tick].
##
## [b]Pushed rather than pulled, and that is what keeps dot-combat and dot-net out of
## this addon.[/b] A candidate is an id, a position, a faction and a loudness — data a
## game already has about its players — so nothing here has to know what a player is.
func set_candidates(candidates: Array) -> void:
	_candidates = candidates
	_candidate_positions.clear()

	for entry in candidates:
		var cand := entry as DotNpcSenses.Candidate

		if cand != null:
			_candidate_positions[cand.id] = cand.position


## Where a candidate was when the list was last set, or [param fallback].
func candidate_position(id: StringName, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	var found: Variant = _candidate_positions.get(id)
	return found if found is Vector3 else fallback


func candidate_count() -> int:
	return _candidates.size()


# --- The tick -----------------------------------------------------------------

## One simulated tick: perceive, think, reclaim.
##
## The order is not arbitrary. Perception first so a brain thinks about this tick's
## world rather than the last one's; reclaim last so an NPC that acquired a target this
## tick is not reclaimed in the same tick for having had none.
func tick(delta: float) -> void:
	if not authoritative:
		return

	_now += delta
	_ticks += 1

	_perceive()
	_think(delta)
	_reclaim()


func _perceive() -> void:
	if senses == null or limits == null:
		return

	var period := maxi(limits.sense_period_ticks, 1)
	var slot := 0

	for id in _npcs:
		var npc: DotNpcInstance = _npcs[id]

		if not npc.is_alive():
			continue

		# Staggered rather than everybody on the same tick.
		#
		# [b]This is the difference between a spike and a cost.[/b] Ninety NPCs
		# sensing every fourth tick together is ninety raycast sweeps in one frame and
		# nothing in the other three; the same work spread over the four is a quarter
		# of the spike for exactly the same total. The slot is the NPC's position in
		# the dictionary rather than its instance id, because instance ids from one
		# allocation run are consecutive and would put every NPC of one wave in the
		# same slot — which is the spike again, with the appearance of a fix.
		slot += 1

		if (slot + _ticks) % period != 0:
			continue

		var before := npc.target_id
		var after := senses.update_target(
			npc, _candidates, _now, limits.sense_candidate_cap
		)

		if after != before:
			target_changed.emit(npc, after)


func _think(delta: float) -> void:
	# A copy, because a brain may kill its NPC — a suicide bomber is the obvious one —
	# and removing from the dictionary being iterated skips every other NPC.
	var ids: Array = _npcs.keys()

	for id in ids:
		var found: Variant = _npcs.get(id)

		if not (found is DotNpcInstance):
			continue

		var npc: DotNpcInstance = found

		if not npc.is_alive() or npc.brain == null:
			continue

		(npc.brain as DotNpcBrain).think(delta)


func _reclaim() -> void:
	if limits == null or limits.reclaim_distance <= 0.0:
		return

	if _candidates.is_empty():
		# Nobody to be far from. Reclaiming here would empty a server the moment its
		# last player disconnected, and a dedicated server between rounds is exactly
		# that — with the wave it is about to hand the next player already spawned.
		return

	var ids: Array = _npcs.keys()
	var limit_sq := limits.reclaim_distance * limits.reclaim_distance

	for id in ids:
		var found: Variant = _npcs.get(id)

		if not (found is DotNpcInstance):
			continue

		var npc: DotNpcInstance = found

		if not npc.is_alive() or npc.has_target():
			continue

		if _now - npc.engaged_at < limits.reclaim_grace:
			continue

		var nearest_sq := INF
		var position := npc.position()

		for entry in _candidates:
			var cand := entry as DotNpcSenses.Candidate

			if cand != null:
				nearest_sq = minf(nearest_sq, position.distance_squared_to(cand.position))

		if nearest_sq > limit_sq:
			reclaim_count += 1
			remove(npc.instance_id, REASON_RECLAIMED)


# --- Spawning -----------------------------------------------------------------

## Spawns one NPC. Null on refusal, with [signal refused] emitted.
func spawn(
	npc_id: StringName,
	at: Vector3,
	owner_id: StringName = &"",
	orientation: Basis = Basis.IDENTITY
) -> DotNpcInstance:
	if not authoritative:
		_refuse(owner_id, npc_id, "This client may not spawn NPCs.")
		return null

	if catalogue == null:
		_refuse(owner_id, npc_id, "This server has no NPC catalogue.")
		return null

	var def := catalogue.get_npc(npc_id)

	if def == null or not def.enabled:
		_refuse(owner_id, npc_id, "No such NPC.")
		return null

	var allowed := may_spawn(def, owner_id)

	if not allowed.ok:
		_refuse(owner_id, npc_id, allowed.error.message)
		return null

	var placement := place(at)

	if not placement.ok:
		_refuse(owner_id, npc_id, placement.error.message)
		return null

	if not ResourceLoader.exists(def.scene_path):
		# Distinguished from "no such NPC" because the two need different fixes: this
		# one is a pack that is not mounted, and telling an operator "no such NPC"
		# sends them to edit a catalogue that is already right.
		_refuse(owner_id, npc_id, "That NPC's content is not loaded on this server.")
		return null

	var scene: Resource = load(def.scene_path)

	if not (scene is PackedScene):
		_refuse(owner_id, npc_id, "That NPC's scene is not a PackedScene.")
		return null

	var resolved := _resolve_world()

	if not resolved.ok:
		_refuse(owner_id, npc_id, resolved.error.message)
		return null

	var node := (scene as PackedScene).instantiate()

	if not (node is Node3D):
		node.queue_free()
		_refuse(owner_id, npc_id, "That NPC's scene is not a Node3D.")
		return null

	var body := node as Node3D
	body.global_transform = Transform3D(orientation, placement.value)

	(resolved.value as Node).add_child(body)

	var npc := DotNpcInstance.new()
	npc.def = def
	npc.node = body
	npc.instance_id = body.get_instance_id()
	npc.owner_id = owner_id
	npc.spawned_at = _now
	npc.engaged_at = _now
	npc.health = def.max_health

	_npcs[npc.instance_id] = npc
	_by_kind[def.id] = int(_by_kind.get(def.id, 0)) + 1

	if not _by_owner.has(owner_id):
		_by_owner[owner_id] = []

	(_by_owner[owner_id] as Array).append(npc.instance_id)

	_last_spawn[owner_id] = _now
	spawn_count += 1

	var attached := attach_brain(npc)

	if not attached.ok:
		# The NPC still exists. A brain that would not load is a broken script, and
		# deleting the NPC would hide which one — an inert NPC standing in the world is
		# a thing an operator can see and name, which is the whole point of the log
		# line beside it.
		DotLog.warn(CHANNEL, "an NPC spawned without its brain", {
			"npc": String(def.id),
			"why": attached.error.message,
		})

	spawned.emit(npc)

	return npc


## Spawns up to [param count] of one kind around [param at]. Returns what was made.
##
## Capped by [member DotNpcLimits.burst_cap], which is the difference between a
## director asking for a wave and a bug asking for ten thousand.
func spawn_group(
	npc_id: StringName,
	at: Vector3,
	count: int,
	spread: float = 3.0,
	owner_id: StringName = &""
) -> Array[DotNpcInstance]:
	var out: Array[DotNpcInstance] = []
	var wanted := count if limits == null else mini(count, limits.burst_cap)

	for i in wanted:
		# A deterministic ring rather than random jitter. Two servers replaying the
		# same director decisions then place a wave identically, which is what makes a
		# horde reproducible in a suite — and randomness here would buy nothing a
		# player could see.
		var angle := TAU * float(i) / float(maxi(wanted, 1))
		var offset := Vector3(cos(angle), 0.0, sin(angle)) * spread
		var made := spawn(npc_id, at + offset, owner_id)

		if made != null:
			out.append(made)

	return out


## Whether one more of [param def] may exist right now.
func may_spawn(def: DotNpcDef, owner_id: StringName = &"") -> DotResult:
	if limits == null:
		return DotResult.success(null)

	if limits.spawn_interval > 0.0 and _last_spawn.has(owner_id):
		var elapsed := _now - float(_last_spawn[owner_id])

		if elapsed < limits.spawn_interval:
			return DotResult.fail(
				DotError.CODE_RATE_LIMITED,
				"Spawning too fast.",
				"%.2f s of %.2f s" % [elapsed, limits.spawn_interval]
			)

	if limits.world_budget > 0 and world_cost() + def.cost > limits.world_budget:
		return DotResult.fail(
			DotError.CODE_QUOTA,
			"The world is at its NPC budget.",
			"%d of %d" % [world_cost(), limits.world_budget]
		)

	if limits.per_kind_cap > 0 and count_of(def.id) >= limits.per_kind_cap:
		return DotResult.fail(
			DotError.CODE_QUOTA,
			"There are already as many of those as this server allows.",
			"%d of %d" % [count_of(def.id), limits.per_kind_cap]
		)

	return DotResult.success(null)


## Where an NPC asked for at [param at] would actually stand.
##
## Separated from [method spawn] so a director can ask before it commits — a wave that
## found only three legal positions out of eight should spawn three rather than eight
## in a wall.
func place(at: Vector3) -> DotResult:
	if limits == null or not limits.require_navigable_spawn:
		return DotResult.success(at)

	if not has_nav():
		# No navigation is not the same as "off the navigation".
		#
		# A game that paths its own way — a flat arena, a 2D game, one using Godot's
		# NavigationServer — has no DotNpcNavData and every spawn point in it is legal.
		# Refusing here would make `require_navigable_spawn` mean "refuse every spawn
		# on a map with no nav data", which is a server with no NPCs at all and a
		# setting that reads as though it should be on.
		return DotResult.success(at)

	# Asked for the INDEX, not for the snapped position.
	#
	# `snap()` returns the point it was handed when there is nothing within the
	# radius, which is the right answer for a caller nudging a position and exactly
	# the wrong one for a caller deciding whether a spawn is legal: the distance from
	# a point to itself is zero, so a spawn two hundred metres off the graph measured
	# as perfect. The first version of this did that, and the check that caught it is
	# the one that spawns something in the middle of nowhere.
	var index := nav.data.nearest_point(at, limits.spawn_snap_radius)

	if index < 0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"There is nowhere to stand there.",
			"nothing navigable within %.1f m" % limits.spawn_snap_radius
		)

	return DotResult.success(nav.data.points[index])


## Builds and attaches the brain named by the definition.
##
## Loaded by path, for the reason in [DotNpcBrain]: a `class_name` cannot be resolved
## inside a mounted pack.
func attach_brain(npc: DotNpcInstance) -> DotResult:
	if npc == null or npc.def == null:
		return DotResult.fail(DotError.CODE_INVALID, "No NPC to give a brain to.")

	if npc.def.brain_script_path == "":
		return DotResult.success(null)

	if not ResourceLoader.exists(npc.def.brain_script_path):
		return DotResult.fail(
			DotError.CODE_IO, "That brain script is not here.",
			npc.def.brain_script_path
		)

	var script: Resource = load(npc.def.brain_script_path)

	if not (script is GDScript):
		return DotResult.fail(
			DotError.CODE_INVALID, "That brain is not a GDScript.",
			npc.def.brain_script_path
		)

	var made: Variant = (script as GDScript).new()

	if not (made is DotNpcBrain):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A brain must extend dot_npc_brain.gd.",
			npc.def.brain_script_path
		)

	npc.brain = made
	(made as DotNpcBrain).bind(npc, self)

	return DotResult.success(made)


func _refuse(owner_id: StringName, npc_id: StringName, reason: String) -> void:
	refusal_count += 1
	refused.emit(owner_id, npc_id, reason)


# --- Damage -------------------------------------------------------------------

## Hurts an NPC. Returns how much health it actually lost.
##
## [b]Health is handled here when dot-combat is absent and handed to it when it is
## present[/b] — but this addon does not import dot-combat and never will, for the
## family's reason. A game with dot-combat gives its NPC scene a health component and
## calls [method report_death] from it; a game without one calls this. Both end at the
## same [signal died], which is what lets a scoring layer be written once.
func damage(instance_id: int, amount: float, by: StringName = &"") -> float:
	if not authoritative or amount <= 0.0:
		return 0.0

	var npc := get_npc(instance_id)

	if npc == null or not npc.is_alive():
		return 0.0

	var before := npc.health
	npc.health = maxf(npc.health - amount, 0.0)

	# Being hurt is being engaged, whoever did it and from wherever.
	#
	# Without this an NPC shot from beyond its sight range is a reclaim candidate while
	# somebody is actively killing it, and the player watches their target vanish.
	npc.engaged_at = _now

	# The brain is told before the signal, and it is told at all.
	#
	# `DotNpcBrain._npc_damaged` was declared, documented and called by nothing in the
	# first version of this file — the family's most repeated bug, in a new addon,
	# caught by the suite asserting the hook rather than the signal. A hook nothing
	# fires is a game whose NPCs never flinch, never call for help and never flee, with
	# no error anywhere.
	if npc.brain != null:
		(npc.brain as DotNpcBrain).damaged(before - npc.health, by)

	damaged.emit(npc, before - npc.health, by)

	if npc.health <= 0.0:
		report_death(instance_id, by)

	return before - npc.health


## Declares an NPC dead. Called by [method damage], or by a game whose health is
## dot-combat's.
func report_death(instance_id: int, by: StringName = &"") -> bool:
	var npc := get_npc(instance_id)

	if npc == null or not npc.alive:
		return false

	npc.health = 0.0
	kill_count += 1

	# Announced while the node still exists, and the brain is told before anything
	# else: dropping a loot bag needs a position, and after `remove` there is none.
	if npc.brain != null:
		(npc.brain as DotNpcBrain).died(by)

	died.emit(npc, by)

	return remove(instance_id, REASON_KILLED)


## Heals an NPC, never above its definition's maximum.
func heal(instance_id: int, amount: float) -> float:
	var npc := get_npc(instance_id)

	if npc == null or not npc.is_alive() or amount <= 0.0:
		return 0.0

	var before := npc.health
	npc.health = minf(npc.health + amount, npc.def.max_health)

	return npc.health - before


# --- Removing -----------------------------------------------------------------

func remove(instance_id: int, reason: StringName = REASON_ADMIN) -> bool:
	if not authoritative:
		return false

	var found: Variant = _npcs.get(instance_id)

	if not (found is DotNpcInstance):
		return false

	var npc: DotNpcInstance = found

	_npcs.erase(instance_id)

	if _by_kind.has(npc.def.id):
		var left := int(_by_kind[npc.def.id]) - 1

		if left <= 0:
			_by_kind.erase(npc.def.id)
		else:
			_by_kind[npc.def.id] = left

	if _by_owner.has(npc.owner_id):
		(_by_owner[npc.owner_id] as Array).erase(instance_id)

	# Announced BEFORE the node is freed, so a listener holding a reference — a
	# netcode replicating it, a director counting its wave — can let go while it still
	# exists. Freeing first leaves every one of them with a freed object and a null
	# check they did not know they needed.
	removed.emit(npc, reason)

	# Marked dead immediately, which is not the same as freeing the node. queue_free()
	# is deferred, so `is_instance_valid` stays true for the rest of the frame — and a
	# director that checked only the node would keep a reclaimed NPC against its budget
	# for as long as that frame lasts.
	npc.alive = false
	npc.brain = null

	if npc.node != null and is_instance_valid(npc.node):
		npc.node.queue_free()

	return true


## Removes everything one owner spawned. Returns how many went.
func clear_owner(owner_id: StringName, reason: StringName = REASON_CLEANUP) -> int:
	var found: Variant = _by_owner.get(owner_id)

	if not (found is Array):
		return 0

	# Copied before iterating: remove() mutates this array, and iterating a list while
	# removing from it skips every other entry.
	var ids: Array = (found as Array).duplicate()
	var count := 0

	for id in ids:
		if remove(int(id), reason):
			count += 1

	_by_owner.erase(owner_id)
	_last_spawn.erase(owner_id)

	return count


func clear_all(reason: StringName = REASON_ADMIN) -> int:
	var ids: Array = _npcs.keys()
	var count := 0

	for id in ids:
		if remove(int(id), reason):
			count += 1

	return count


## Called by the host when a player disconnects.
func owner_left(owner_id: StringName) -> int:
	if limits != null and not limits.clean_up_on_leave:
		# Kept, but disowned: the NPCs stay and stop counting against a budget nobody
		# is using. A persistent world wants exactly this, and without the disown the
		# budget of a departed player is held for ever.
		_by_owner.erase(owner_id)
		_last_spawn.erase(owner_id)
		return 0

	return clear_owner(owner_id, REASON_LEFT)


# --- Queries ------------------------------------------------------------------

func get_npc(instance_id: int) -> DotNpcInstance:
	var found: Variant = _npcs.get(instance_id)
	return found if found is DotNpcInstance else null


## The NPC a node belongs to, or null. For a shot that hit something.
func npc_for_node(node: Node) -> DotNpcInstance:
	if node == null:
		return null

	# Walks up, because a physics query hits a collider that may be a child of the
	# NPC's own root — which is what a body with several shapes looks like.
	var walk := node

	while walk != null:
		var found: Variant = _npcs.get(walk.get_instance_id())

		if found is DotNpcInstance:
			return found

		walk = walk.get_parent()

	return null


func world_count() -> int:
	return _npcs.size()


func world_cost() -> int:
	var total := 0

	for id in _npcs:
		total += (_npcs[id] as DotNpcInstance).def.cost

	return total


func count_of(npc_id: StringName) -> int:
	return int(_by_kind.get(npc_id, 0))


func count_in_faction(faction: StringName) -> int:
	var total := 0

	for id in _npcs:
		if (_npcs[id] as DotNpcInstance).def.faction == faction:
			total += 1

	return total


## Every live NPC. A copy, because callers walk it to decide what to remove.
func all_npcs() -> Array[DotNpcInstance]:
	var out: Array[DotNpcInstance] = []

	for id in _npcs:
		var npc: DotNpcInstance = _npcs[id]

		if npc.is_alive():
			out.append(npc)

	return out


func npcs_of(owner_id: StringName) -> Array[DotNpcInstance]:
	var out: Array[DotNpcInstance] = []
	var found: Variant = _by_owner.get(owner_id, [])

	if not (found is Array):
		return out

	for id in (found as Array):
		var npc: Variant = _npcs.get(int(id))

		if npc is DotNpcInstance:
			out.append(npc)

	return out


## Live NPCs within [param radius] of [param point]. For an explosion, or a director.
func npcs_near(point: Vector3, radius: float) -> Array[DotNpcInstance]:
	var out: Array[DotNpcInstance] = []
	var radius_sq := radius * radius

	for id in _npcs:
		var npc: DotNpcInstance = _npcs[id]

		if npc.is_alive() and npc.position().distance_squared_to(point) <= radius_sq:
			out.append(npc)

	return out


## Simulated seconds this spawner has run for. What a director's pacing counts in.
func now() -> float:
	return _now


func _resolve_world() -> DotResult:
	if world_ref == null:
		return DotResult.success(self)

	if _world != null and is_instance_valid(_world):
		return DotResult.success(_world)

	var resolved := world_ref.resolve(self)

	if not resolved.ok:
		return resolved.wrap("Could not find where to put spawned NPCs.")

	_world = resolved.value

	return DotResult.success(_world)


func describe() -> Dictionary:
	return {
		"authoritative": authoritative,
		"npcs": _npcs.size(),
		"cost": world_cost(),
		"kinds": _by_kind.size(),
		"spawned": spawn_count,
		"killed": kill_count,
		"reclaimed": reclaim_count,
		"refused": refusal_count,
		"nav": nav.describe() if has_nav() else "none",
		"limits": limits.describe_summary() if limits != null else "none",
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	out.append("npcs         %d (%d cost)" % [_npcs.size(), world_cost()])
	out.append("limits       %s" % (
		limits.describe_summary() if limits != null else "none"
	))
	out.append("navigation   %s" % (
		"%d points" % nav.data.point_count() if has_nav() else "none"
	))
	out.append("spawned %d  killed %d  reclaimed %d  refused %d" % [
		spawn_count, kill_count, reclaim_count, refusal_count
	])

	for kind in _by_kind:
		out.append("  %-16s %d" % [String(kind), int(_by_kind[kind])])

	return out
