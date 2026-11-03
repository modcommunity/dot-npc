class_name DotNpcSpawning
extends RefCounted
## The spawner's spawn path: refusal checks, placement, instantiation, seeding and the brain.

const CHANNEL := "npc"

var s: DotNpcSpawner
## Spawns adopted so far, the fallback subject of [method seed_for]. Never reset, so a
## second round on the same spawner does not replay the first round's choices.
var _spawn_serial: int = 0


func _init(spawner: DotNpcSpawner) -> void:
	s = spawner


## Spawns one NPC. Null on refusal, with [signal refused] emitted.
func spawn(
	npc_id: StringName,
	at: Vector3,
	owner_id: StringName = &"",
	orientation: Basis = Basis.IDENTITY
) -> DotNpcInstance:
	var prepared := _prepare(npc_id, at, owner_id)

	if prepared.is_empty():
		return null

	var def: DotNpcDef = prepared[0]
	var node: Node = prepared[1]
	var placed: Vector3 = prepared[2]

	if not (node is Node3D):
		node.queue_free()
		s._refuse(owner_id, npc_id, "That NPC's scene is not a Node3D.")
		return null

	var body := node as Node3D
	body.global_transform = Transform3D(orientation, placed)

	return _adopt(def, body, owner_id)


## The same spawn, into a 2D world.
## The plane is XZ: `at` is `(x, y)` and becomes `(x, 0, y)` inside this addon. A 2D definition should
## set `line_of_sight` false: there is no 3D physics world to cast through.
func spawn_2d(
	npc_id: StringName,
	at: Vector2,
	owner_id: StringName = &"",
	rotation: float = 0.0
) -> DotNpcInstance:
	var prepared := _prepare(npc_id, DotNpcInstance.to_plane(at), owner_id)

	if prepared.is_empty():
		return null

	var def: DotNpcDef = prepared[0]
	var node: Node = prepared[1]
	var placed: Vector3 = prepared[2]

	if not (node is Node2D):
		node.queue_free()
		s._refuse(owner_id, npc_id, "That NPC's scene is not a Node2D.")
		return null

	var body := node as Node2D
	body.position = DotNpcInstance.from_plane(placed)
	body.rotation = rotation

	return _adopt(def, body, owner_id)


## Everything both spawns do before the node exists: the checks, the placement, and the
## instantiation. Returns `[def, node, placed_position]` or an empty array on a refusal.
func _prepare(npc_id: StringName, at: Vector3, owner_id: StringName) -> Array:
	if not s.authoritative:
		s._refuse(owner_id, npc_id, "This client may not spawn NPCs.")
		return []

	if s.catalogue == null:
		s._refuse(owner_id, npc_id, "This server has no NPC catalogue.")
		return []

	var def := s.catalogue.get_npc(npc_id)

	if def == null or not def.enabled:
		s._refuse(owner_id, npc_id, "No such NPC.")
		return []

	var allowed := may_spawn(def, owner_id)

	if not allowed.ok:
		s._refuse(owner_id, npc_id, allowed.error.message)
		return []

	var placement := place(at)

	if not placement.ok:
		s._refuse(owner_id, npc_id, placement.error.message)
		return []

	if not s._held.has(def.scene_path) and not ResourceLoader.exists(def.scene_path):
		# Distinguished from "no such NPC" because the two need different fixes: this
		# one is a pack that is not mounted, and telling an operator "no such NPC"
		# sends them to edit a catalogue that is already right.
		s._refuse(owner_id, npc_id, "That NPC's content is not loaded on this server.")
		return []

	var scene: Resource = s._resource(def.scene_path)

	if not (scene is PackedScene):
		s._refuse(owner_id, npc_id, "That NPC's scene is not a PackedScene.")
		return []

	return [def, (scene as PackedScene).instantiate(), placement.value]


## Puts a placed node into the world and into the books, and gives it its brain.
## The world is resolved here, after the node exists, in a way that does not leak the instantiated
## scene when the world cannot be resolved.
func _adopt(def: DotNpcDef, body: Node, owner_id: StringName) -> DotNpcInstance:
	var resolved := s._resolve_world()

	if not resolved.ok:
		body.queue_free()
		s._refuse(owner_id, def.id, resolved.error.message)
		return null

	(resolved.value as Node).add_child(body)

	var npc := DotNpcInstance.new()
	npc.def = def
	npc.node = body
	npc.instance_id = body.get_instance_id()
	npc.owner_id = owner_id
	npc.spawned_at = s._now
	npc.engaged_at = s._now
	npc.health = def.max_health

	npc.seed = _seed_npc(npc)

	s._npcs[npc.instance_id] = npc
	s._by_kind[def.id] = int(s._by_kind.get(def.id, 0)) + 1

	if not s._by_owner.has(owner_id):
		s._by_owner[owner_id] = []

	(s._by_owner[owner_id] as Array).append(npc.instance_id)

	s._last_spawn[owner_id] = s._now
	s.spawn_count += 1

	var attached := attach_brain(npc)

	if not attached.ok:
				# The NPC still exists: deleting one whose brain would not load hides which script is broken,
				# and an inert NPC is something an operator can see and name beside the log line.
		DotLog.warn(CHANNEL, "an NPC spawned without its brain", {
			"npc": String(def.id),
			"why": attached.error.message,
		})

	s.spawned.emit(npc)

	return npc


## The seed an NPC gets for [param subject], a stable per-spawn number. Above 1, always.
## Two stream names, so the game's number 5 and this spawner's fifth spawn are different seeds
## when seed_source answers for some NPCs and not others.
func seed_for(subject: int, from_game: bool = false) -> int:
	var stream := DotRandomStream.new(s.seed_base).stream_for(
		&"npc_id" if from_game else &"npc", subject
	)

	# 2..2^31-1: positive and small enough to survive a float, and never 0 or 1, which
	# dot-npc-ai reads as "this character still has the preset's seed".
	return stream.range_i_at(0, 2, 0x7FFFFFFF)


func _seed_npc(npc: DotNpcInstance) -> int:
	_spawn_serial += 1

	if s.seed_source.is_valid():
		var given: Variant = s.seed_source.call(npc)

		if (given is int) and int(given) != 0:
			return seed_for(int(given), true)

	return seed_for(_spawn_serial)


## Spawns up to [param count] of one kind around [param at]. Returns what was made.
## Capped by [member DotNpcLimits.burst_cap]: a director asking for a wave versus a bug asking for ten thousand.
func spawn_group(
	npc_id: StringName,
	at: Vector3,
	count: int,
	spread: float = 3.0,
	owner_id: StringName = &""
) -> Array[DotNpcInstance]:
	var out: Array[DotNpcInstance] = []
	var wanted := count if s.limits == null else mini(count, s.limits.burst_cap)

	for i in wanted:
				# A deterministic ring, not random jitter: two servers replaying the same decisions place a
				# wave identically, which makes a horde reproducible in a suite.
		var angle := TAU * float(i) / float(maxi(wanted, 1))
		var offset := Vector3(cos(angle), 0.0, sin(angle)) * spread
		var made := spawn_2d(npc_id, DotNpcInstance.from_plane(at + offset), owner_id) \
			if s.two_dimensional else spawn(npc_id, at + offset, owner_id)

		if made != null:
			out.append(made)

	return out


## Whether one more of [param def] may exist right now.
func may_spawn(def: DotNpcDef, owner_id: StringName = &"") -> DotResult:
	if s.limits == null:
		return DotResult.success(null)

	if s.limits.spawn_interval > 0.0 and s._last_spawn.has(owner_id):
		var elapsed := s._now - float(s._last_spawn[owner_id])

		if elapsed < s.limits.spawn_interval:
			return DotResult.fail(
				DotError.CODE_RATE_LIMITED,
				"Spawning too fast.",
				"%.2f s of %.2f s" % [elapsed, s.limits.spawn_interval]
			)

	if s.limits.world_budget > 0 and s.world_cost() + def.cost > s.limits.world_budget:
		return DotResult.fail(
			DotError.CODE_QUOTA,
			"The world is at its NPC budget.",
			"%d of %d" % [s.world_cost(), s.limits.world_budget]
		)

	if s.limits.per_kind_cap > 0 and s.count_of(def.id) >= s.limits.per_kind_cap:
		return DotResult.fail(
			DotError.CODE_QUOTA,
			"There are already as many of those as this server allows.",
			"%d of %d" % [s.count_of(def.id), s.limits.per_kind_cap]
		)

	return DotResult.success(null)


## Where an NPC asked for at [param at] would actually stand.
## Separate from [method spawn] so a director can ask first: a wave with three legal positions of eight
## should spawn three, not eight in a wall.
func place(at: Vector3) -> DotResult:
	if s.limits == null or not s.limits.require_navigable_spawn:
		return DotResult.success(at)

	if not s.has_nav():
				# No navigation is not "off the navigation": a game that paths its own way has no DotNpcNavData and
				# every spawn point is legal. Refusing would make `require_navigable_spawn` mean "refuse every
				# spawn on a map with no nav data".
		return DotResult.success(at)

		# Asked for the INDEX, not the snapped position: `snap()` returns its input when nothing is within
		# the radius, and the distance from a point to itself is zero, so a spawn two hundred metres off
		# the graph measured as perfect.
	var index := s.nav.data.nearest_point(at, s.limits.spawn_snap_radius)

	if index < 0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"There is nowhere to stand there.",
			"nothing navigable within %.1f m" % s.limits.spawn_snap_radius
		)

	return DotResult.success(s.nav.data.points[index])


## Builds and attaches the brain named by the definition.
## Loaded by path, as in [DotNpcBrain]: a class_name cannot be resolved inside a mounted pack.
func attach_brain(npc: DotNpcInstance) -> DotResult:
	if npc == null or npc.def == null:
		return DotResult.fail(DotError.CODE_INVALID, "No NPC to give a brain to.")

	if npc.def.brain_script_path == "":
		return DotResult.success(null)

	if not s._held.has(npc.def.brain_script_path) and not ResourceLoader.exists(npc.def.brain_script_path):
		return DotResult.fail(
			DotError.CODE_IO, "That brain script is not here.",
			npc.def.brain_script_path
		)

	var script: Resource = s._resource(npc.def.brain_script_path)

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
	(made as DotNpcBrain).bind(npc, s)

	return DotResult.success(made)