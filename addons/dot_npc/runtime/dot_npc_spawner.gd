@tool
class_name DotNpcSpawner
extends Node

## Spawns, senses, thinks, hurts and reclaims. The node a game with NPCs adds.
## Server-authoritative, NPCs not predicted (pathfinder and solver are not reproducible); see [DotNpcNetSync].
## It does not own the tick: the game calls [method tick] at its fixed rate, so a suite can step it a thousand times.

const CHANNEL := "npc"

## An NPC entered the world.
signal spawned(npc: DotNpcInstance)

## One left it. [param reason] is one of the REASON_* constants.
signal removed(npc: DotNpcInstance, reason: StringName)

## An NPC took damage. Fired after the health has already been reduced.
signal damaged(npc: DotNpcInstance, amount: float, by: StringName)

## Its health reached zero. Fired before [signal removed], while the node still exists.
## Separate from [signal removed]: dying scores and drops loot, reclaiming is a director tidying up.
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
## Every mutating method refuses first on a non-authoritative spawner: a client that could spawn fills the world.
@export var authoritative: bool = false

## Whether this spawner serves a 2D world.
## One flag set beside `authoritative`: a spawner serves one world. [method spawn_group] and [DotNpcDirector]
## read it; [method spawn] and [method spawn_2d] stay separate, since a Vector3 caller and a Vector2 caller differ.
@export var two_dimensional: bool = false

@export_group("Randomness")

## The session's seed for NPC choices: every NPC's [member DotNpcInstance.seed] is derived from it.
## A game sets it from its own session or match seed so a replay can be given the recorded run's.
## Left at zero, the same spawns make the same choices, which is what a suite wants.
@export var seed_base: int = 0

## The game's own stable number for an NPC, or none. `func(npc: DotNpcInstance) -> int`.
## Called once per spawn before the brain is bound; usually the entity id. Zero or no callable falls back to the
## spawn count. A [Callable] because naming dot-entity would break parsing without it. Never return `get_instance_id()`.
var seed_source: Callable = Callable()

@export_group("Navigation")

## Remove the corners the grid put in a path that the world does not have.
## On: a two-metre grid turns in eight directions, so NPCs would walk a visible staircase.
## Off is for a game whose own follower smooths.
@export var smooth_paths: bool = true

## How many of a path's first points are smoothed; 0 smooths all of it.
## A follower walks a few metres of a path before repathing, so the far end is smoothed for nobody, and
## smoothing whole paths was most of a path's cost on a fifteen-thousand-point map. 16 suits a 1.5 s repath.
@export var smooth_horizon: int = 0

## Walk toward an unreachable goal rather than standing still.
## On, as in [method DotNpcBrain.steer_along_path]: an NPC that stops dead when the generator missed a corner
## is a bug nobody can see the cause of.
@export var allow_partial_paths: bool = true

@export_group("Perception")

## Physics collision mask the line-of-sight raycast uses.
@export_flags_3d_physics var occlusion_mask: int = 1

## Navigation for the map currently loaded, or null for a game that paths its own way.
var nav: DotNpcNavGraph = null

## Path -> the scene or brain script loaded from it, held for as long as the spawner lives.
## See [method warm].
var _held: Dictionary = {}

## Shared perception. One object, because its tuning is the world's rather than an
## NPC's — two NPCs that gave up on a target at different ranges would be a game
## design decision, and it belongs in the definition, not in a second senses object.
var senses: DotNpcSenses = null

## Worker threads ranking candidates for a perception pass ([method DotNpcSenses.rank], over
## packed data); rays and commitment stay on this thread. 0 inline, -1 automatic. A host copies
## its own setting here (dot-server's [code]sv_threads_npc[/code]); off on a machine without threads.
var sense_workers: int = 0

## NPCs ranked per worker task: fewer, larger tasks keep the fork cheap.
const SENSE_CHUNK := 16

## How far a goal may move before a path is recomputed, in metres.
var repath_drift: float = 2.5

## The goal may also move this share of the distance to it before a repath: a chaser far off
## does not need a new route for every step its quarry takes. 0 is [member repath_drift] alone.
var repath_drift_ratio: float = 0.0

## Seconds between forced repaths even when the goal has not moved.
var repath_interval: float = 1.5

## Seconds per metre to the goal added to the forced repath: a far NPC re-plans less often than
## one at its quarry's heels. 0 is [member repath_interval] alone.
var repath_interval_per_m: float = 0.0

## Worker threads answering a tick's repaths together ([method DotNpcNavGraph.find_paths]).
## 0 searches inline. Above 0 (-1 automatic) a repath is queued and answered after every brain has thought,
## so that think follows the old path. A host copies dot-server's `sv_threads_npc` here.
var path_workers: int = 0

## Worker threads for the decide step of brains that [method DotNpcBrain.splits_think] and are thread safe.
## 0 decides inline. The result is identical either way: apply runs in NPC order after the join.
var think_workers: int = 0

var _pathing := DotNpcPathing.new(self)
var _perception := DotNpcPerception.new(self)
var _spawning := DotNpcSpawning.new(self)

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


## Adopts navigation for the map now loaded. Null clears it.
## Called on every map change: navigation is per map, and a stale graph walks NPCs through walls,
## which is worse than none.
func set_nav_data(data: DotNpcNavData) -> DotResult:
	_pathing.reset()

	if data == null:
		nav = null
		return DotResult.success(null)

	var graph := DotNpcNavGraph.new()
	var built := graph.rebuild(data)

		# Logged here, where a nav file meets the running server. Refused is WARN (NPCs walk straight at goals;
		# regenerate the file); adopted is INFO once per map, since "NPCs walk through walls" is first answered
		# by whether navigation loaded at all.
	if not built.ok:
		nav = null
		DotLog.warn(CHANNEL, "navigation refused; npcs will walk straight at goals", {
			"map": String(data.map_id), "why": built.error.message,
		})
		return built.wrap("Navigation for this map was refused.")

	nav = graph

	DotLog.info(CHANNEL, "navigation adopted", {
		"map": String(data.map_id),
		"points": data.point_count(),
		"edges": data.edge_count(),
	})

	return DotResult.success(nav)


func has_nav() -> bool:
	return nav != null and nav.is_ready()


## The next point [param npc] should walk toward to reach [param goal].
## Called by [DotNpcBrain.steer_along_path]. Recomputes the path when drifted or expired, and returns
## the goal itself when there is no navigation, which is the documented fallback.
func path_toward(npc: DotNpcInstance, path: DotNpcPath, goal: Vector3) -> Vector3:
	return _pathing.path_toward(npc, path, goal)


## Answers every repath queued this tick, on [member path_workers]; [method tick] calls it after
## the brains think. The paths get exactly what an inline search would have given them.
func answer_paths() -> void:
	_pathing.answer()


## What the NPCs may perceive this tick. Called by the host before [method tick].
## Pushed, not pulled, which keeps dot-combat and dot-net out of this addon: a candidate is an id,
## a position, a faction and a loudness.
func set_candidates(candidates: Array) -> void:
	_candidates = candidates
	_candidate_positions.clear()

	for entry in candidates:
		var cand := entry as DotNpcSenses.Candidate

		if cand != null:
			_candidate_positions[cand.id] = cand.position


## Every candidate's position from the last [method set_candidates] (what a level-of-detail scheduler measures from).
func candidate_positions() -> Array:
	return _candidate_positions.values()


## Where a candidate was when the list was last set, or [param fallback].
func candidate_position(id: StringName, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	var found: Variant = _candidate_positions.get(id)
	return found if found is Vector3 else fallback


func candidate_count() -> int:
	return _candidates.size()


## The candidates last handed to [method set_candidates], as the same array (not a copy, which a per-tick
## copy of every player would make costly). Treat it as read-only. Lets a pack read who the NPCs
## perceive without reaching for the private field.
func candidates() -> Array:
	return _candidates


## One simulated tick: perceive, think, reclaim.
## Perception first so a brain thinks about this tick's world; reclaim last so an NPC that acquired
## a target this tick is not reclaimed for having had none.
func tick(delta: float) -> void:
	if not authoritative:
		return

	_now += delta
	_ticks += 1

	_perception.perceive()
	_think(delta)
	_perception.reclaim()


func _think(delta: float) -> void:
	# A copy, because a brain may kill its NPC — a suicide bomber is the obvious one —
	# and removing from the dictionary being iterated skips every other NPC.
	var ids: Array = _npcs.keys()
	var split: Array = []
	var gathered: Array = []

	for id in ids:
		var found: Variant = _npcs.get(id)

		if not (found is DotNpcInstance):
			continue

		var npc: DotNpcInstance = found

		if not npc.is_alive() or npc.brain == null:
			continue

		var brain := npc.brain as DotNpcBrain

		if brain.splits_think():
			brain.age += delta
			split.append(brain)
			gathered.append(brain._npc_gather(delta))
		else:
			brain.think(delta)

	if not split.is_empty():
		_decide_and_apply(split, gathered)

	answer_paths()


## Decide for every gathered brain (pooled when allowed and every brain is thread safe), then apply in gather order.
func _decide_and_apply(split: Array, gathered: Array) -> void:
	var pooled := split.all(func(b: DotNpcBrain) -> bool: return b.is_thread_safe())
	var intents := DotParallel.run(
		func(i: int) -> Variant: return (split[i] as DotNpcBrain)._npc_decide(gathered[i]),
		split.size(), &"npc_think", think_workers if pooled else 0,
		func(a: Variant, b: Variant) -> String: return "" if var_to_str(a) == var_to_str(b) else "%s vs %s" % [a, b]
	)

	for i in split.size():
		var brain: DotNpcBrain = split[i]

		# An earlier apply may have killed this NPC (a blast); its intent is dropped, as a dead brain's think is.
		if brain.npc != null and brain.npc.is_alive():
			brain._npc_apply(intents[i])


## Spawns one NPC. Null on refusal, with [signal refused] emitted.
func spawn(
	npc_id: StringName,
	at: Vector3,
	owner_id: StringName = &"",
	orientation: Basis = Basis.IDENTITY
) -> DotNpcInstance:
	return _spawning.spawn(npc_id, at, owner_id, orientation)


## The same spawn, into a 2D world.
## The plane is XZ: `at` is `(x, y)` and becomes `(x, 0, y)` inside this addon. A 2D definition should
## set `line_of_sight` false: there is no 3D physics world to cast through.
func spawn_2d(
	npc_id: StringName,
	at: Vector2,
	owner_id: StringName = &"",
	rotation: float = 0.0
) -> DotNpcInstance:
	return _spawning.spawn_2d(npc_id, at, owner_id, rotation)


## The seed an NPC gets for [param subject], a stable per-spawn number. Above 1, always.
## Two stream names, so the game's number 5 and this spawner's fifth spawn are different seeds
## when seed_source answers for some NPCs and not others.
func seed_for(subject: int, from_game: bool = false) -> int:
	return _spawning.seed_for(subject, from_game)


## Spawns up to [param count] of one kind around [param at]. Returns what was made.
## Capped by [member DotNpcLimits.burst_cap]: a director asking for a wave versus a bug asking for ten thousand.
func spawn_group(
	npc_id: StringName,
	at: Vector3,
	count: int,
	spread: float = 3.0,
	owner_id: StringName = &""
) -> Array[DotNpcInstance]:
	return _spawning.spawn_group(npc_id, at, count, spread, owner_id)


## Whether one more of [param def] may exist right now.
func may_spawn(def: DotNpcDef, owner_id: StringName = &"") -> DotResult:
	return _spawning.may_spawn(def, owner_id)


## Where an NPC asked for at [param at] would actually stand.
## Separate from [method spawn] so a director can ask first: a wave with three legal positions of eight
## should spawn three, not eight in a wall.
func place(at: Vector3) -> DotResult:
	return _spawning.place(at)


## Builds and attaches the brain named by the definition.
## Loaded by path, as in [DotNpcBrain]: a class_name cannot be resolved inside a mounted pack.
func attach_brain(npc: DotNpcInstance) -> DotResult:
	return _spawning.attach_brain(npc)


func _refuse(owner_id: StringName, npc_id: StringName, reason: String) -> void:
	refusal_count += 1
	refused.emit(owner_id, npc_id, reason)


## Hurts an NPC. Returns how much health it actually lost.
## Handled here when dot-combat is absent; a game with dot-combat calls [method report_death] from its health
## component instead. Both end at the same [signal died], so scoring is written once.
func damage(instance_id: int, amount: float, by: StringName = &"") -> float:
	if not authoritative or amount <= 0.0:
		return 0.0

	var npc := get_npc(instance_id)

	if npc == null or not npc.is_alive():
		return 0.0

	var before := npc.health
	npc.health = maxf(npc.health - amount, 0.0)

		# Being hurt is being engaged, from wherever: otherwise an NPC shot from beyond its sight range
		# is a reclaim candidate while being killed.
	npc.engaged_at = _now

		# The brain is told before the signal, and at all: `DotNpcBrain._npc_damaged` was once declared and
		# called by nothing, so NPCs never flinched, called for help or fled, with no error anywhere.
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

		# Announced BEFORE the node is freed, so a listener holding a reference (netcode, a wave counter)
		# lets go while it still exists.
	removed.emit(npc, reason)

		# Marked dead immediately, not at free: queue_free() is deferred, so `is_instance_valid` stays true
		# and a reclaimed NPC would keep counting against the budget for the rest of the frame.
	npc.alive = false
	_unbind(npc)

	if npc.node != null and is_instance_valid(npc.node):
		npc.node.queue_free()

	return true


## Breaks the NPC <-> brain cycle. See [method DotNpcBrain.unbind].
## Called from [method remove] and when this spawner is freed. Clearing only `npc.brain` is not the fix:
## the brain's own context points back at the brain.
func _unbind(npc: DotNpcInstance) -> void:
	if npc == null:
		return

	if npc.brain is DotNpcBrain:
		(npc.brain as DotNpcBrain).unbind()

	npc.brain = null


## Everything still bound when the spawner goes away.
## PREDELETE, not `_exit_tree`: a spawner reparented during a map change must keep its NPCs thinking.
func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return

	for id in _npcs:
		var npc: Variant = _npcs[id]

		if npc is DotNpcInstance:
			_unbind(npc)


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


## Loads every catalogue kind's scene and brain script now, and holds them. Returns how many resources were loaded.
## A kind's first spawn compiles its brain (30 ms a kind in a measured game), a hitch a host avoids by calling
## this while a map loads. Held, because a resource nothing references is freed and recompiled on the next spawn.
func warm() -> int:
	var count := 0

	if catalogue == null:
		return count

	for def: DotNpcDef in catalogue.npcs:
		if def == null or not def.enabled:
			continue

		for path: String in [def.scene_path, def.brain_script_path]:
			if path != "" and not _held.has(path) and ResourceLoader.exists(path):
				if _resource(path) != null:
					count += 1

	return count


## [param path] loaded once and held. See [method warm].
func _resource(path: String) -> Resource:
	var found: Variant = _held.get(path)

	if found != null:
		return found

	var loaded := load(path)

	if loaded != null:
		_held[path] = loaded

	return loaded


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
		"seed_base": seed_base,
		"seeded_by": "game" if seed_source.is_valid() else "spawn count",
		"nav": nav.describe() if has_nav() else "none",
		"path_workers": DotParallel.resolve_workers(path_workers),
		"think_workers": DotParallel.resolve_workers(think_workers),
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
