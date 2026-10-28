extends "res://examples/selftest/brain_tests.gd"

## Proves the population holds, the senses commit, the graph paths and nothing leaks.
## [b]The tests that matter are the ones no count can pass by accident[/b]: a target that flickers between two people,
## a graph that joins a walkway to the floor below, a reclaim that deletes what is chasing someone. Real nodes, real tree.


const CHECKS := 239 + 23 + 15 + 6 + 3 + 4 + 4 + 3 + 13 + 4 + 2 + 11 + 3 + 3 + 3 + 2 + 3 + 2 + 3 + 2

## Sections entered against sections that ran to their last line. A runtime error inside a section aborts that
## function and nothing says so; a section that bailed early after a failed guard counts as unfinished on purpose.
## CHECKS is the other half; see docs/testing.md.
const SECTIONS := 40

func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("dot-npc self-test")
	print("")

	_world = Node3D.new()
	add_child(_world)

	_test_definitions()
	_test_catalogue()
	_test_profiles()
	_test_limits()
	_test_nav_data()
	_test_nav_builder()
	_test_nav_graph()
	_test_nav_at_scale()
	_test_nav_smoothing()
	_test_nav_filter()
	_test_nav_partial()
	_test_nav_cover()
	_test_path()
	await _test_senses_basics()
	_test_senses_commitment()
	_test_senses_grace()
	_test_senses_cap()
	_test_senses_pruning()
	_test_senses_workers()
	_test_senses_quiet()
	_test_target_since()
	_test_spawning()
	_test_spawning_2d()
	_test_authority()
	_test_world_budget()
	_test_per_kind_cap()
	_test_spawn_interval()
	_test_navigable_spawn()
	_test_spawner_pathing()
	_test_path_workers()
	_test_brains()
	_test_stable_seeds()
	_test_brains_are_released()
	_test_damage()
	_test_reclaim()
	_test_cleanup()
	# Awaited: an un-awaited coroutine returns at its first `await`, so the leak check would finish
	# after `get_tree().quit()` and never report, which looks like a passing suite one check short.
	await _test_no_leaked_nodes()
	_test_net_sync()
	_test_limbs()
	_test_gore()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	print("%d of %d sections ran to their last line" % [_completed, _entered])
	if _entered != SECTIONS or _completed != _entered:
		print("ERROR: %d sections entered and %d completed, %d expected. One aborted or was skipped." % [
			_entered, _completed, SECTIONS
		])
		get_tree().quit(1)
		return
	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _test_net_sync() -> void:
	_section("replication")

	var specs := DotNpcNetSync.specs()
	_check(specs.size() == 6, "there is a spec for what crosses the wire")

	var by_name := {}
	for spec in specs:
		by_name[spec["property"]] = spec

	_check(
		bool((by_name[&"net_x"] as Dictionary)["interpolated"]),
		"position is interpolated"
	)
	_check(
		not bool((by_name[&"net_health"] as Dictionary)["interpolated"]),
		"and health is not"
	)

	var mirror := RefCounted.new()
	var spawner := _spawner()
	var npc := spawner.spawn(&"walker", Vector3(3, 0, -4))

	# A plain object with the properties set, because dot-net is not here to make a
	# behaviour. What is being tested is the quantisation, not the transport.
	var probe := _NetProbe.new()
	DotNpcNetSync.pull(npc, probe, DotNpcNetSync.State.MOVING)

	_check(probe.net_x == 3.0 and probe.net_z == -4.0, "a pull copies the position")
	_check(probe.net_health == 100, "and full health reads as 100")

	spawner.damage(npc.instance_id, 99.6)
	DotNpcNetSync.pull(npc, probe)
	_check(
		probe.net_health == 1,
		"and an NPC on a sliver of health never reads as 0",
		"a client drawing 0 over something still swinging is telling a lie"
	)

	for degrees in [0, 1, 90, 180, 270, 359]:
		var yaw := deg_to_rad(float(degrees))
		var back := DotNpcNetSync.dequantise_yaw(DotNpcNetSync.quantise_yaw(yaw))
		_check(
			absf(angle_difference(yaw, back)) < deg_to_rad(1.0),
			"yaw survives quantisation at %d degrees" % degrees,
			"%.2f deg out" % rad_to_deg(absf(angle_difference(yaw, back)))
		)

	_check(
		DotNpcNetSync.quantise_yaw(TAU) == 0,
		"and a full turn wraps to zero rather than off the end of the field",
		"one past the largest value truncates to 0 and faces a body backwards"
	)

	var node := Node3D.new()
	_world.add_child(node)
	probe.net_x = 5.0
	probe.net_y = 1.0
	probe.net_z = 6.0
	probe.net_yaw = DotNpcNetSync.quantise_yaw(PI)
	DotNpcNetSync.apply(node, probe)

	_check(node.global_position == Vector3(5, 1, 6), "and a client can apply one")

	# Facing survives the trip. A server body turned by `face` and a client node given the
	# replicated yaw must look the same way — the two halves were each half a turn out,
	# which cancelled on screen and left every server-side sight cone pointing backwards.
	var walker := spawner.spawn(&"walker", Vector3(30, 0, 30))
	if walker != null and walker.brain is DotNpcBrain:
		(walker.brain as DotNpcBrain).face(Vector3(1, 0, 0))
		_check(
			walker.facing().distance_to(Vector3(1, 0, 0)) < 0.01,
			"an NPC told to face +X faces +X",
			"facing %s" % str(walker.facing())
		)
		var mirror_node := Node3D.new()
		_world.add_child(mirror_node)
		var sent := _NetProbe.new()
		sent.net_yaw = DotNpcNetSync.quantise_yaw(DotNpcNetSync.yaw_of(walker))
		DotNpcNetSync.apply(mirror_node, sent)
		_check(
			(-mirror_node.global_transform.basis.z).distance_to(Vector3(1, 0, 0)) < 0.05,
			"and a client given its yaw faces the same way",
			"client faces %s" % str(-mirror_node.global_transform.basis.z)
		)
		mirror_node.queue_free()
	else:
		_check(false, "an NPC told to face +X faces +X", "no walker brain to turn")
		_check(false, "and a client given its yaw faces the same way")

	mirror = null
	node.queue_free()
	spawner.queue_free()
	_done()


## The receiving half of a replication, without dot-net in the project.
class _NetProbe:
	extends RefCounted

	var net_x: float = 0.0
	var net_y: float = 0.0
	var net_z: float = 0.0
	var net_yaw: int = 0
	var net_health: int = 0
	var net_state: int = 0


func _limb_skeleton() -> Skeleton3D:
	var sk := Skeleton3D.new()
	for spec in [["root", -1, Vector3.ZERO], ["head", 0, Vector3(0, 1.7, 0)], ["armL", 0, Vector3(-0.5, 1.4, 0)], ["legL", 0, Vector3(-0.2, 0.9, 0)]]:
		sk.add_bone(spec[0])
		sk.set_bone_parent(sk.get_bone_count() - 1, spec[1])
		sk.set_bone_rest(sk.get_bone_count() - 1, Transform3D(Basis.IDENTITY, spec[2]))
	sk.reset_bone_poses()
	return sk


func _test_limbs() -> void:
	_section("limbs")
	var defs := {
		"head": {"bones": ["head"], "radius": 0.3, "health": 50.0, "kills": true},
		"armL": {"bones": ["armL"], "radius": 0.2, "health": 80.0, "attack": 0.5},
		"legL": {"bones": ["legL"], "radius": 0.2, "health": 80.0, "slow": 0.5, "damage_scale": 2.0},
		"junk": {"radius": 1.0},
	}
	var body := Node3D.new()
	_world.add_child(body)
	var sk := _limb_skeleton()
	body.add_child(sk)
	var limbs := DotNpcLimbs.new()
	limbs.skeleton = sk
	body.add_child(limbs)
	limbs.setup(&"dummy", defs)
	_check(limbs.limb_names() == [&"head", &"armL", &"legL"], "a def without bones is not a limb, order kept")
	_check(limbs.limb_at(Vector3(0, 1.7, 0.1)) == &"head", "a point at the head finds the head")
	_check(limbs.limb_at(Vector3(5, 5, 5)) == &"", "a point far away finds nothing")
	_check(limbs.hit(Vector3(0, 1.7, 0), 20.0) == &"" and not limbs.is_severed(&"head"), "a shot that does not finish a limb leaves it on")
	_check(limbs.hit(Vector3(0, 1.7, 0), 40.0) == &"head" and limbs.is_severed(&"head"), "the shot that spends its health severs it")
	_check(limbs.is_lethal(), "a head with kills makes the NPC lethal")
	_check(limbs.limb_at(Vector3(0, 1.7, 0)) != &"head", "a severed limb is not hit again")
	_check(limbs.mask() == 1, "the mask has the head's bit")
	_check(limbs.hit(Vector3(-0.2, 0.9, 0), 40.0) == &"legL", "damage_scale multiplies what a limb takes")
	_check(is_equal_approx(limbs.speed_scale(), 0.5) and limbs.attack_scale() == 1.0, "a lost leg slows, and arms are unaffected")
	var mirror := DotNpcLimbs.new()
	body.add_child(mirror)
	mirror.setup(&"dummy", defs)
	var seen: Array = []
	mirror.severed.connect(func(l, _i): seen.append(l))
	mirror.apply_mask(limbs.mask())
	_check(mirror.is_severed(&"head") and mirror.is_severed(&"legL") and not mirror.is_severed(&"armL") and seen.size() == 2, "a client mirror severs exactly what the mask says")
	mirror.apply_mask(0)
	_check(mirror.is_severed(&"head"), "a limb never grows back")
	_check(DotNpcLimbs.defs_from_config(&"no_such_definition").is_empty(), "no configured limbs is an empty set, not an error")
	var specs := DotNpcNetSync.limb_specs()
	_check(specs.size() == 1 and specs[0]["property"] == &"net_limbs" and specs[0]["bits"] >= DotNpcLimbs.MAX_LIMBS, "replication carries the mask as one field")
	_check(DotNpcGibs.subtree(sk, 0).size() == 4 and DotNpcGibs.subtree(sk, 2).size() == 1, "a limb's subtree is its bone and what hangs below")
	# hit_limb names the limb: overlapping regions cannot sever a different one.
	var named := DotNpcLimbs.new()
	body.add_child(named)
	named.setup(&"dummy", defs)
	_check(named.hit_limb(&"armL", Vector3(0, 1.7, 0), 100.0) == &"armL" and named.is_severed(&"armL") and not named.is_severed(&"head"), "hit_limb hurts the named limb, not the one the point is in")
	_check(named.hit_limb(&"armL", Vector3.ZERO, 100.0) == &"" and named.hit_limb(&"nope", Vector3.ZERO, 100.0) == &"", "hit_limb ignores a gone or unknown limb")
	# A late joiner shows the stump silently: no gib or blood path, and a finite point.
	var stub := _LimbView.new()
	body.add_child(stub)
	var late := DotNpcLimbs.new()
	body.add_child(late)
	late.setup(&"dummy", defs, stub)
	var infos: Array = []
	late.severed.connect(func(_l, i): infos.append(i))
	late.apply_mask(3)
	_check(stub.severed.is_empty() and stub.stumps == [&"head", &"armL"], "apply_mask draws stumps, not severs", str(stub.stumps))
	_check(infos.size() == 2 and is_finite((infos[0]["point"] as Vector3).x) and infos[0]["point"] != Vector3.INF, "a mask-applied limb reports a finite point")
	late.sever(&"legL", Vector3(0, 1, 0), Vector3.UP)
	_check(stub.severed == [&"legL"], "a live sever still takes the gib path")
	# A recycled body starts whole.
	late.setup(&"dummy", defs, stub)
	_check(late.mask() == 0 and not late.is_severed(&"head") and stub.restores == 1, "setup resets the severed set and restores the view")
	body.queue_free()
	_done()


func _test_gore() -> void:
	_section("gore level")
	DotNpcGore.reset()
	_check(DotNpcGore.level == 2 and DotNpcGore.gibs_enabled() and DotNpcGore.spray_enabled(), "the default is gibs and spray (level 2)")
	DotNpcGore.level = 9
	_check(DotNpcGore.level == DotNpcGore.MAX_LEVEL and is_equal_approx(DotNpcGore.health_scale(), 0.6), "a level clamps to 3, where limbs give way sooner")
	DotNpcGore.level = -4
	_check(DotNpcGore.level == 0 and not DotNpcGore.dismember_enabled(), "a level clamps to 0, where nothing comes off")
	DotNpcGore.level = 1
	_check(DotNpcGore.dismember_enabled() and not DotNpcGore.gibs_enabled() and not DotNpcGore.spray_enabled(), "level 1 is stumps only")
	DotNpcGore.level = 2
	DotNpcGore.max_gibs = 0
	_check(not DotNpcGore.gibs_enabled() and DotNpcGore.spray_enabled(), "a gib cap of 0 throws no limb but keeps the spray")
	DotNpcGore.reset()
	var defs := {"armL": {"bones": ["armL"], "radius": 0.2, "health": 80.0}}
	var make := func() -> DotNpcLimbs:
		var l := DotNpcLimbs.new()
		_world.add_child(l)
		l.setup(&"gore", defs)
		return l
	var off: DotNpcLimbs = make.call()
	DotNpcGore.level = 0
	_check(off.hit_limb(&"armL", Vector3.ZERO, 500.0) == &"" and off.mask() == 0, "level 0: a shot of any size takes no limb")
	off.apply_mask(1)
	_check(off.mask() == 0, "level 0: a replicated mask shows nothing")
	DotNpcGore.level = 2
	_check(off.hit_limb(&"armL", Vector3.ZERO, 79.0) == &"", "level 2: 79 of 80 holds")
	var soft: DotNpcLimbs = make.call()
	DotNpcGore.level = 3
	_check(soft.hit_limb(&"armL", Vector3.ZERO, 50.0) == &"armL", "level 3: 50 takes a limb of 80 (x0.6)")
	DotNpcGore.reset()
	DotNpcGore.view_cap = DotNpcGore.STUMPS
	_check(DotNpcGore.drawn_level() == 1 and not DotNpcGore.gibs_enabled() and not DotNpcGore.spray_enabled() and not DotNpcGore.wounds_enabled(),
		"a player's cap of 1 draws clean stumps only, whatever the rule")
	var capped: DotNpcLimbs = make.call()
	_check(capped.hit_limb(&"armL", Vector3.ZERO, 500.0) == &"armL", "and the cap never changes what the rules let come off")
	DotNpcGore.level = 0
	DotNpcGore.view_cap = 3
	_check(DotNpcGore.drawn_level() == 0, "a rule of 0 caps what a player can ask to see")
	DotNpcGore.level = 2
	DotNpcGore.view_cap = 0
	var hidden: DotNpcLimbs = make.call()
	hidden.apply_mask(1)
	_check(hidden.mask() == 0, "a player's cap of 0 draws no stump from a replicated mask")
	DotNpcGore.level = 0
	DotNpcGore.view_cap = 3
	hidden.sever(&"armL", Vector3.INF, Vector3.ZERO)
	_check(hidden.mask() == 0, "level 0: sever() takes nothing either")
	DotNpcGore.reset()
	DotNpcGore.max_wounds = 0
	_check(not DotNpcGore.wounds_enabled() and DotNpcGibs.add_wound(null, Vector3.ZERO) == null and DotNpcGibs.add_pool(null, Vector3.ZERO) == null,
		"a wound cap of 0 draws no marks or pools")
	DotNpcGore.reset()
	off.queue_free()
	soft.queue_free()
	capped.queue_free()
	hidden.queue_free()
	_done()


## The same spawner, into a 2D world.
## Only the placement differs, so check the mapping onto the plane and that the wrong entry point refuses
## (a scene instantiated then rejected is a leaked node nothing reports).
func _test_spawning_2d() -> void:
	_section("spawning in 2D")

	var world_2d := Node2D.new()
	_world.add_child(world_2d)

	var spawner := DotNpcSpawner.new()
	spawner.catalogue = _catalogue()
	spawner.limits = _limits()
	spawner.authoritative = true
	spawner.two_dimensional = true
	spawner.world_ref = DotNodeRef.of_path(^"..")
	world_2d.add_child(spawner)

	var swarmer := spawner.spawn_2d(&"swarmer", Vector2(120.0, -40.0))

	_check(swarmer != null, "a 2D NPC spawns")
	_check(swarmer != null and swarmer.is_alive(), "and its node is in the tree")
	_check(swarmer != null and swarmer.is_2d(), "and it knows it is 2D")
	_check(
		swarmer != null and swarmer.position_2d().is_equal_approx(Vector2(120.0, -40.0)),
		"where it was asked for",
		str(swarmer.position_2d()) if swarmer != null else "null"
	)

	# The plane is XZ, and this check says so: everything here measures a 3D distance, which on a
	# plane where one component never moves IS the 2D distance. A wrong mapping makes sight range 300 mean nothing.
	_check(
		swarmer != null and swarmer.position().is_equal_approx(Vector3(120.0, 0.0, -40.0)),
		"and reads back in the XZ plane the senses measure in",
		str(swarmer.position()) if swarmer != null else "null"
	)
	_check(
		DotNpcInstance.from_plane(DotNpcInstance.to_plane(Vector2(3.0, -7.0)))
			== Vector2(3.0, -7.0),
		"the mapping round-trips"
	)

	# Perception, which is the half a 2D game is actually here for.
	spawner.set_candidates([
		_candidate(&"player_near", DotNpcInstance.to_plane(Vector2(160.0, -40.0))),
		_candidate(&"player_far", DotNpcInstance.to_plane(Vector2(4000.0, -40.0))),
	])
	# Several ticks, because perception is staggered across `sense_period_ticks` — ninety
	# NPCs sensing on the same tick is a spike and the same work spread over four is not.
	# A test that ticked once would be asserting which slot this NPC landed in.
	for _sense in range(8):
		spawner.tick(1.0 / 60.0)

	_check(
		swarmer.target_id == &"player_near",
		"it commits to the nearer of two candidates (%s)" % String(swarmer.target_id)
	)

	# And it moves. `steer_toward` has no 2D branch worth the name if the body never goes
	# anywhere, and a brain that silently does nothing is dot-npc's own most repeated bug.
	var before := swarmer.position_2d()

	for _step in range(20):
		spawner.tick(1.0 / 60.0)

	_check(
		swarmer.position_2d().distance_to(before) > 1.0,
		"and walks toward it (%.1f units)" % swarmer.position_2d().distance_to(before)
	)

	var children := world_2d.get_child_count()

	_check(
		spawner.spawn_2d(&"walker", Vector2.ZERO) == null,
		"a 3D NPC asked for in 2D is refused"
	)
	_check(
		spawner.spawn(&"swarmer", Vector3.ZERO) == null,
		"and a 2D NPC asked for in 3D"
	)
	_check(
		world_2d.get_child_count() == children,
		"leaving nothing behind either time",
		"%d children, was %d" % [world_2d.get_child_count(), children]
	)

	# A wave. `spawn_2d_group` is one flag rather than a second copy of the ring
	# arithmetic, because a second copy is a second place the deterministic layout drifts.
	var wave := spawner.spawn_group(&"swarmer", Vector3(400.0, 0.0, 400.0), 4, 30.0)

	_check(wave.size() == 4, "a group spawns four (%d)" % wave.size())
	_check(
		wave.size() == 4 and wave[0].is_2d() and wave[3].is_2d(),
		"and every one of them is 2D"
	)
	_check(
		wave.size() == 4
			and wave[0].position_2d().distance_to(wave[2].position_2d()) > 30.0,
		"spread around the point rather than stacked on it"
	)

	world_2d.queue_free()
	_done()

class _LimbView extends Node3D:
	var severed: Array = []
	var stumps: Array = []
	var restores := 0

	func sever_limb(limb: StringName, _d: Dictionary, _impulse: Vector3) -> Vector3:
		severed.append(limb)
		return Vector3(0, 1, 0)

	func stump_limb(limb: StringName, _d: Dictionary) -> Vector3:
		stumps.append(limb)
		return Vector3(0, 1, 0)

	func restore_limbs() -> void:
		restores += 1


## A campaign-sized map: the indexes added for it must answer what a scan does, and fast.
## Equality against brute force: a bucket index that missed a neighbouring bucket would still find a point, just not the nearest.
func _test_nav_at_scale() -> void:
	_section("navigation at scale")

	var started := Time.get_ticks_msec()
	var builder := DotNpcNavBuilder.new()
	builder.spacing = 1.0
	builder.point_radius = 1.0
	builder.clearance = 0.35
	builder.generate_cover = false
	builder.add_floor(AABB(Vector3(-60, 0, -40), Vector3(120, 0, 80)), 0.0)

	# A street grid of blocks, so there are walls everywhere a bucket boundary could fall.
	for bx in range(-5, 5):
		for bz in range(-3, 3):
			builder.add_obstacle(AABB(Vector3(bx * 12.0 + 2.0, 0, bz * 12.0 + 2.0), Vector3(6.5, 4, 6.5)))

	var nav := builder.build(&"scale", "digest")
	var built_ms := Time.get_ticks_msec() - started

	_check(nav.point_count() > 6000, "a 120 by 80 metre map at one metre is thousands of points", "%d" % nav.point_count())
	_check(built_ms < 20000, "and it builds in seconds, not minutes", "%d ms" % built_ms)

	var mismatches := 0
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242

	for i in 300:
		var probe := Vector3(rng.randf_range(-65, 65), rng.randf_range(-0.5, 0.5), rng.randf_range(-45, 45))
		var radius := rng.randf_range(0.2, 6.0)
		var indexed := nav.nearest_point(probe, radius)
		var scanned := -1
		var best := INF

		for j in nav.points.size():
			var d := nav.points[j].distance_squared_to(probe)
			if d <= radius * radius and d < best:
				best = d
				scanned = j

		if indexed != scanned:
			mismatches += 1

	_check(mismatches == 0, "the bucket index answers exactly what a scan of every point does", "%d of 300 differ" % mismatches)

	var graph := DotNpcNavGraph.new(nav)
	started = Time.get_ticks_msec()
	var path := graph.find_path(Vector3(-58, 0, -38), Vector3(58, 0, 38), 1.5)
	var path_ms := Time.get_ticks_msec() - started

	_check(not path.is_empty(), "a path crosses the whole map")
	_check(path_ms < 1500, "in well under a second", "%d ms" % path_ms)

	var walled := false
	for k in range(1, path.size()):
		for bx in range(-5, 5):
			for bz in range(-3, 3):
				var block := AABB(Vector3(bx * 12.0 + 2.0, -1, bz * 12.0 + 2.0), Vector3(6.5, 6, 6.5))
				if block.has_point(path[k - 1].lerp(path[k], 0.5)):
					walled = true

	_check(not walled, "and no step of it goes through a block")

	# The native search (AStar3D) against the script A* it replaced: same path length for random pairs, with and
	# without a filter that makes some ground dearer, and much faster. Same length, not same points (equal-cost routes tie).
	var script_graph := DotNpcNavGraph.new(nav)
	script_graph.use_native_search = false
	var dear := DotNpcNavFilter.new()
	dear.set_area_cost(DotNpcNavData.AREA_GROUND, 1.0)
	var longer := 0
	var native_us := 0
	var script_us := 0
	# Each filter's AStar3D is built on its first search; build both before timing.
	graph.filter = dear
	var _warm := graph.find_path(Vector3(-58, 0, -38), Vector3(58, 0, 38), 1.5)

	for i in 40:
		var a := Vector3(rng.randf_range(-58, 58), 0, rng.randf_range(-38, 38))
		var b := Vector3(rng.randf_range(-58, 58), 0, rng.randf_range(-38, 38))
		graph.filter = dear if i % 2 == 1 else null
		script_graph.filter = graph.filter
		var t0 := Time.get_ticks_usec()
		var fast := graph.find_path(a, b, 1.5)
		var t1 := Time.get_ticks_usec()
		var slow := script_graph.find_path(a, b, 1.5)
		var t2 := Time.get_ticks_usec()
		native_us += t1 - t0
		script_us += t2 - t1
		if fast.is_empty() != slow.is_empty() or absf(_path_length(fast) - _path_length(slow)) > 0.01:
			longer += 1

	_check(longer == 0, "the native search finds paths as short as the script A*", "%d of 40 differ" % longer)
	_check(native_us * 4 < script_us, "and at a fraction of the cost", "%d us against %d us" % [native_us, script_us])
	_done()


func _test_nav_smoothing() -> void:
	_section("navigation smoothing")

	# An empty room. Every waypoint between the ends is the grid's, not the world's.
	var builder := DotNpcNavBuilder.new()
	builder.spacing = 2.0
	builder.add_floor(AABB(Vector3(-12, 0, -12), Vector3(24, 0, 24)), 0.0)

	var graph := DotNpcNavGraph.new(builder.build(&"open", "digest"))
	var from := Vector3(-9, 0, -9)
	var to := Vector3(9, 0, 9)

	var raw := graph.find_path(from, to, 3.0)
	var smooth := graph.smooth_path(raw)

	_check(raw.size() > 4, "a grid path across an open room has many waypoints",
		"%d" % raw.size())
	_check(
		smooth.size() < raw.size(),
		"and smoothing removes the ones the world does not have",
		"%d -> %d" % [raw.size(), smooth.size()]
	)

	var straight := from.distance_to(to)
	_check(
		_path_length(smooth) <= _path_length(raw) + 0.001,
		"a smoothed path is never longer than the one it came from",
		"%.2f m against %.2f m" % [_path_length(smooth), _path_length(raw)]
	)
	_check(
		_path_length(smooth) < straight * 1.15,
		"and across an empty room it is very nearly the straight line",
		"%.2f m against %.2f m straight" % [_path_length(smooth), straight]
	)

	_check(
		smooth[0] == from and smooth[smooth.size() - 1] == to,
		"and it still begins and ends where the caller is"
	)

	# A horizon smooths the head and leaves the tail as the graph gave it: same ends, the
	# raw tail points still there, and no longer than the raw path.
	var head := graph.smooth_path(raw, -1.0, 8, 3)
	var tail_kept := raw.size() > 4 and head[head.size() - 2] == raw[raw.size() - 2]
	_check(
		head[0] == from and head[head.size() - 1] == to and tail_kept and _path_length(head) <= _path_length(raw) + 0.001,
		"a smoothing horizon smooths the head of a path and keeps its tail",
		"%d raw, %d with a horizon of 3, %d smoothed" % [raw.size(), head.size(), smooth.size()]
	)

	# The one that matters. Smoothing is a shortcut and a shortcut through a wall is
	# worse than the staircase it replaced.
	var wall := AABB(Vector3(-2, 0, -12), Vector3(4, 4, 20))
	var bent := DotNpcNavBuilder.new()
	bent.spacing = 2.0
	bent.add_floor(AABB(Vector3(-12, 0, -12), Vector3(24, 0, 24)), 0.0)
	bent.add_obstacle(wall)

	var bent_graph := DotNpcNavGraph.new(bent.build(&"bent", "digest"))
	var around := bent_graph.find_smooth_path(Vector3(-8, 0, 0), Vector3(8, 0, 0), 3.0)

	_check(not around.is_empty(), "a smoothed path is still found around a wall")
	_check(
		not _path_enters(around, wall),
		"and no leg of it cuts through the wall it went round"
	)

	_check(
		bent_graph.can_walk_straight(Vector3(-8, 0, 8), Vector3(-8, 0, -8)),
		"a clear line is walkable"
	)
	_check(
		not bent_graph.can_walk_straight(Vector3(-8, 0, 0), Vector3(8, 0, 0)),
		"and one through the wall is not"
	)

	# The leg memo answers what the tests would: the same path asked twice, and without it.
	var memo_raw := bent_graph.find_path(Vector3(-8, 0, 0), Vector3(8, 0, 0), 3.0)
	var memo_first := bent_graph.smooth_path(memo_raw)
	var memo_again := bent_graph.smooth_path(memo_raw)
	bent_graph.memo_legs = false
	var memo_off := bent_graph.smooth_path(memo_raw)
	bent_graph.memo_legs = true
	_check(
		memo_first == memo_again and memo_first == memo_off and not _path_enters(memo_again, wall),
		"a remembered leg smooths a path as testing it again would",
		"%d, %d, %d points" % [memo_first.size(), memo_again.size(), memo_off.size()]
	)

	var two := PackedVector3Array([from, to])
	_check(
		graph.smooth_path(two).size() == 2,
		"a path with nothing to remove comes back unchanged"
	)
	_done()


func _test_nav_filter() -> void:
	_section("navigation filter")

	# The water strip is added first, because the first floor to claim a grid cell
	# keeps it — so the ground added afterwards fills in around it.
	var builder := DotNpcNavBuilder.new()
	builder.spacing = 2.0
	builder.generate_cover = false
	# Aligned with the ground grid on purpose: both floors start on an odd metre so their cells coincide.
	# Offset grids give two interleaved sets of points and the strip stops being a barrier (a generator's usual mistake).
	var water := AABB(Vector3(-4, 0, -6), Vector3(8, 0, 12))
	builder.add_floor(water, 0.0, DotNpcNavData.AREA_WATER)
	builder.add_floor(AABB(Vector3(-14, 0, -14), Vector3(28, 0, 28)), 0.0)

	var nav := builder.build(&"pond", "digest")
	var wet := 0
	for i in nav.point_count():
		if nav.area_of(i) == DotNpcNavData.AREA_WATER:
			wet += 1

	_check(wet > 0, "a floor can be given an area id", "%d wet points" % wet)
	_check(wet < nav.point_count(), "and the rest of the map keeps its own")

	var graph := DotNpcNavGraph.new(nav)
	var from := Vector3(-10, 0, 0)
	var to := Vector3(10, 0, 0)

	var straight_through := graph.find_path(from, to, 3.0)
	_check(
		_path_visits(straight_through, water),
		"with no filter the shortest way is straight through the water"
	)

	var filter := DotNpcNavFilter.new()
	_check(filter.set_area_cost(DotNpcNavData.AREA_WATER, 20.0).ok, "an area can cost more")
	_check(
		not filter.set_area_cost(DotNpcNavData.AREA_WATER, 0.0).ok,
		"and cannot cost nothing: a free step makes A* prefer a cycle"
	)
	_check(not filter.set_area_cost(999, 2.0).ok, "an area id out of range is refused")

	graph.filter = filter
	var around := graph.find_path(from, to, 3.0)

	_check(not around.is_empty(), "a costly area is still passable")
	_check(
		not _path_visits(around, water),
		"and the path goes round it when going round is cheaper"
	)
	_check(
		_path_length(around) > _path_length(straight_through),
		"which is a longer walk, deliberately",
		"%.1f m against %.1f m" % [
			_path_length(around), _path_length(straight_through)
		]
	)

	# The whole reason cost beats a ban: make the detour expensive enough and the NPC
	# wades, rather than standing at the edge of the puddle for ever.
	filter.set_area_cost(DotNpcNavData.AREA_WATER, 1.05)
	var wading := graph.find_path(from, to, 3.0)
	_check(
		_path_visits(wading, water),
		"and it wades when the detour is worse than the crossing"
	)

	# Flags are the other half: impassable rather than expensive.
	var crouch_builder := DotNpcNavBuilder.new()
	crouch_builder.spacing = 2.0
	crouch_builder.generate_cover = false
	crouch_builder.add_floor(
		AABB(Vector3(-4, 0, -30), Vector3(8, 0, 60)), 0.0,
		DotNpcNavData.AREA_GROUND, DotNpcNavData.Flag.CROUCH
	)
	crouch_builder.add_floor(AABB(Vector3(-14, 0, -14), Vector3(28, 0, 28)), 0.0)

	var tunnel := DotNpcNavGraph.new(crouch_builder.build(&"tunnel", "digest"))
	_check(
		not tunnel.find_path(from, to, 3.0).is_empty(),
		"something that can crouch gets through a crouch corridor"
	)

	tunnel.filter = DotNpcNavFilter.walking_only()
	_check(
		tunnel.find_path(from, to, 3.0).is_empty(),
		"and something that cannot, does not"
	)

	# The filter refuses the start point too. Without that an NPC standing at the
	# mouth of the tunnel snaps onto a point it may not occupy and every path from it
	# fails at the first edge, which reads as a broken graph rather than a filter.
	_check(
		tunnel.find_path(Vector3(0, 0, 0), Vector3(10, 0, 0), 1.5).is_empty(),
		"standing on an excluded point is not a place to path from"
	)

	_check(DotNpcNavFilter.neutral().is_neutral(), "a neutral filter says so")
	_check(not DotNpcNavFilter.walking_only().is_neutral(), "and a real one does not")
	_check(
		not DotNpcNavFilter.neutral().duplicate_filter().is_neutral() == false,
		"a filter can be copied"
	)
	_done()


func _test_senses_basics() -> void:
	_section("senses")

	var senses := DotNpcSenses.new()
	var def := DotNpcDef.make(&"seer", BODY)
	def.sight_range = 20.0
	def.sight_half_angle_deg = 60.0
	def.hearing_range = 5.0
	def.require_line_of_sight = false

	var npc := _loose_npc(def)

	_check(
		senses.perceives(npc, _candidate(&"a", Vector3(0, 0, -10))),
		"something in front and in range is seen"
	)
	_check(
		not senses.perceives(npc, _candidate(&"a", Vector3(0, 0, 10))),
		"something behind is not"
	)
	_check(
		not senses.perceives(npc, _candidate(&"a", Vector3(0, 0, -50))),
		"and neither is something beyond the range"
	)
	_check(
		senses.perceives(npc, _candidate(&"a", Vector3(0, 0, 3), &"player", 8.0)),
		"but something loud behind is heard",
		"an NPC that only saw could be walked up behind for ever"
	)
	_check(
		not senses.perceives(npc, _candidate(&"a", Vector3(0, 0, 3), &"player", 1.0)),
		"and something quiet behind is not"
	)
	_check(
		not senses.perceives(npc, _candidate(&"z", Vector3(0, 0, -5), &"hostile")),
		"and its own faction is never a target"
	)

	# The per-NPC scale: one attentive NPC of a kind sees further than the kind does, and
	# a dull one less far, without a second definition.
	npc.sight_scale = 3.0
	_check(
		senses.perceives(npc, _candidate(&"a", Vector3(0, 0, -50))),
		"a sight scale of 3 sees what the kind's range does not"
	)
	npc.sight_scale = 0.25
	_check(
		not senses.perceives(npc, _candidate(&"a", Vector3(0, 0, -10))),
		"and one of a quarter does not see what the kind would"
	)

	# Standing on a real floor, with line of sight on: the sight line must not start at the feet, ON the floor,
	# or every NPC on a floor is blind.
	var ground := StaticBody3D.new()
	var slab := CollisionShape3D.new()
	var slab_box := BoxShape3D.new()
	slab_box.size = Vector3(40, 0.2, 40)
	slab.shape = slab_box
	slab.position = Vector3(0, -0.1, 0)
	ground.add_child(slab)
	var wall := CollisionShape3D.new()
	var wall_box := BoxShape3D.new()
	wall_box.size = Vector3(4, 4, 0.2)
	wall.shape = wall_box
	wall.position = Vector3(8, 2, -5)
	ground.add_child(wall)
	_world.add_child(ground)
	await get_tree().physics_frame

	var looker_def := DotNpcDef.make(&"looker", BODY)
	looker_def.sight_range = 20.0
	looker_def.sight_half_angle_deg = 80.0
	var looker := _loose_npc(looker_def, Vector3(0, 0, 0))
	senses.occlusion_mask = 0xFFFFFFFF
	_check(senses.perceives(looker, _candidate(&"a", Vector3(0, 1, -8))),
		"an NPC standing on a floor sees what is in front of it")
	var behind_wall := _loose_npc(looker_def, Vector3(8, 0, 0))
	_check(not senses.perceives(behind_wall, _candidate(&"a", Vector3(8, 1, -10))),
		"and not through a wall")
	ground.queue_free()
	_done()


func _test_spawner_pathing() -> void:
	_section("spawner pathing")

	var limits := _limits()
	limits.spawn_snap_radius = 3.0

	var spawner := _spawner(limits)

	var builder := DotNpcNavBuilder.new()
	builder.spacing = 2.0
	builder.generate_cover = false
	# A crouch tunnel joining two rooms, and nothing else joining them.
	builder.add_floor(AABB(Vector3(-4, 0, -4), Vector3(8, 0, 8)), 0.0)
	builder.add_floor(
		AABB(Vector3(4, 0, -2), Vector3(12, 0, 4)), 0.0,
		DotNpcNavData.AREA_GROUND, DotNpcNavData.Flag.CROUCH
	)
	builder.add_floor(AABB(Vector3(16, 0, -4), Vector3(8, 0, 8)), 0.0)

	spawner.set_nav_data(builder.build(&"tunnel", "digest"))
	_check(spawner.has_nav(), "the tunnel map is adopted")

	var npc := spawner.spawn(&"walker", Vector3(-2, 0, 0))
	_check(npc != null, "an NPC spawns in the near room")

	var goal := Vector3(18, 0, 0)
	var path := DotNpcPath.new()
	var step := spawner.path_toward(npc, path, goal)

	_check(not path.is_empty(), "and paths through the tunnel to the far room")
	_check(step != goal, "so its next step is a waypoint rather than the goal itself")
	_check(not path.partial, "and the path is not partial")

	# The same map, the same NPC, one flag on its definition. Nothing else changes.
	npc.def.nav_exclude_flags = DotNpcNavData.Flag.CROUCH

	var blocked_path := DotNpcPath.new()
	var blocked_step := spawner.path_toward(npc, blocked_path, goal)

	_check(
		blocked_path.is_empty() or blocked_path.partial,
		"an NPC that cannot crouch does not get a path through a crouch tunnel",
		"which is the definition's flag reaching the graph's filter"
	)
	_check(
		blocked_step != goal or blocked_path.is_empty(),
		"and is not simply handed the goal as if the tunnel were open"
	)

	# Smoothing is on by default and is the reason a path is worth following. Turning
	# it off must produce more waypoints for the same walk, or nothing is smoothing.
	npc.def.nav_exclude_flags = 0

	var open := DotNpcNavBuilder.new()
	open.spacing = 2.0
	open.generate_cover = false
	open.add_floor(AABB(Vector3(-12, 0, -12), Vector3(24, 0, 24)), 0.0)
	spawner.set_nav_data(open.build(&"open", "digest"))

	var far := Vector3(9, 0, 9)
	npc.node.global_position = Vector3(-9, 0, -9)

	var smooth := DotNpcPath.new()
	spawner.path_toward(npc, smooth, far)

	spawner.smooth_paths = false
	var rough := DotNpcPath.new()
	spawner.path_toward(npc, rough, far)

	_check(
		smooth.points.size() < rough.points.size(),
		"the spawner smooths by default, and turning it off is visible",
		"%d smoothed against %d raw" % [smooth.points.size(), rough.points.size()]
	)

	# A follower stuck on a cut corner asks for the graph's own corners for a while, then gets
	# smoothed paths again.
	spawner.smooth_paths = true
	smooth.go_rough(spawner.now(), 2.0)
	spawner.path_toward(npc, smooth, far)
	var while_rough := smooth.points.size()
	smooth.rough_until = -INF
	smooth.clear()
	spawner.path_toward(npc, smooth, far)
	_check(
		while_rough == rough.points.size() and smooth.points.size() < while_rough,
		"go_rough() gives a stuck follower the unsmoothed path, and only while it lasts",
		"%d rough, %d after" % [while_rough, smooth.points.size()]
	)

	# The flag has to survive a catalogue round trip, or a delivered NPC loses the one
	# thing that keeps it out of a tunnel it cannot use.
	var def := DotNpcDef.make(&"crawler", "res://x.tscn")
	def.nav_exclude_flags = DotNpcNavData.Flag.CROUCH | DotNpcNavData.Flag.JUMP
	var back := DotNpcDef.from_dictionary(def.to_dictionary())
	_check(
		back.nav_exclude_flags == def.nav_exclude_flags,
		"and it survives a definition round trip"
	)

	var plain := DotNpcDef.from_dictionary(DotNpcDef.make(&"x", "res://x.tscn").to_dictionary())
	_check(plain.nav_exclude_flags == 0, "a definition without one keeps none")

	var path_flag := DotNpcPath.new()
	path_flag.partial = true
	path_flag.set_points(PackedVector3Array([Vector3.ZERO, Vector3.ONE]), 0.0, Vector3.ONE)
	_check(
		not path_flag.partial,
		"new points clear the partial flag, so it never describes the previous path"
	)
	_check(path_flag.reaches_goal(), "and a complete path says it reaches its goal")

	# A far goal that moves a little re-plans only with the plain drift, not with a drift ratio.
	npc.node.global_position = Vector3(-9, 0, -9)
	var drifting := DotNpcPath.new()
	spawner.path_toward(npc, drifting, far)
	var searched := spawner.nav.searches
	spawner.path_toward(npc, drifting, far + Vector3(3, 0, 0))
	_check(spawner.nav.searches == searched + 1, "a goal that moved past the drift is searched for again")
	spawner.repath_drift_ratio = 0.5
	spawner.path_toward(npc, drifting, far + Vector3(6, 0, 0))
	_check(spawner.nav.searches == searched + 1, "but with a drift ratio a far one does not re-plan for a small move")
	spawner.repath_drift_ratio = 0.0
	spawner.repath_interval_per_m = 1.0
	drifting.computed_at = spawner.now() - 5.0
	spawner.path_toward(npc, drifting, far + Vector3(3, 0, 0))
	_check(spawner.nav.searches == searched + 1, "and an interval per metre holds the forced repath off for a far goal")

	spawner.queue_free()
	_done()


func _test_path_workers() -> void:
	_section("path workers")

	var builder := DotNpcNavBuilder.new()
	builder.spacing = 2.0
	builder.generate_cover = false
	builder.add_floor(AABB(Vector3(-20, 0, -20), Vector3(40, 0, 40)), 0.0)
	builder.add_floor(
		AABB(Vector3(20, 0, -2), Vector3(10, 0, 4)), 0.0,
		DotNpcNavData.AREA_GROUND, DotNpcNavData.Flag.CROUCH
	)
	builder.add_floor(AABB(Vector3(30, 0, -8), Vector3(16, 0, 16)), 0.0)
	builder.add_floor(AABB(Vector3(60, 0, 60), Vector3(6, 0, 6)), 0.0)

	for k in 3:
		builder.add_obstacle(AABB(Vector3(-12 + k * 10, 0, -16 + (k % 2) * 8), Vector3(1, 3, 24)))

	var data := builder.build(&"workers", "digest")
	var graph := DotNpcNavGraph.new(data)
	var crouchless := DotNpcNavFilter.new()
	crouchless.exclude_flags = DotNpcNavData.Flag.CROUCH
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var goals: Array[Vector3] = [Vector3(40, 0, 0), Vector3(62, 0, 62), Vector3(500, 0, 500)]
	var queries: Array = []

	for i in 48:
		var q := DotNpcNavGraph.PathQuery.new()
		q.from = Vector3(rng.randf_range(-18, 18), 0, rng.randf_range(-18, 18))
		q.to = goals[i % 3] if i % 4 == 0 else Vector3(rng.randf_range(-18, 44), 0, rng.randf_range(-18, 18))
		q.filter = crouchless if i % 2 == 0 else null
		q.snap_radius = 3.0
		q.allow_partial = i % 3 != 0
		q.smooth = i % 5 != 0
		q.horizon = 16 if i % 7 == 0 else 0
		queries.append(q)

	# What each query gets asked alone, the way path_toward always asked it.
	var alone: Array = []
	var partials: Array = []
	var before := Vector2i(graph.searches, graph.failures)

	for q: DotNpcNavGraph.PathQuery in queries:
		graph.filter = q.filter
		alone.append(
			graph.find_smooth_path(q.from, q.to, q.snap_radius, q.allow_partial, q.horizon) if q.smooth
			else graph.find_path(q.from, q.to, q.snap_radius, q.allow_partial)
		)
		partials.append(graph.last_partial)

	graph.filter = null
	var counted := Vector2i(graph.searches, graph.failures) - before
	var kinds := {"empty": 0, "partial": 0, "whole": 0}

	for i in alone.size():
		var key := "empty" if (alone[i] as PackedVector3Array).is_empty() else ("partial" if partials[i] else "whole")
		kinds[key] += 1

	_check(
		kinds["empty"] > 0 and kinds["partial"] > 0 and kinds["whole"] > 0,
		"the batch covers whole, partial and unreachable answers", str(kinds)
	)

	for workers in [0, 4]:
		var searched := Vector2i(graph.searches, graph.failures)
		graph.find_paths(queries, workers)
		var same := 0

		for i in queries.size():
			var q: DotNpcNavGraph.PathQuery = queries[i]
			if q.points == alone[i] and q.partial == partials[i]:
				same += 1

		_check(
			same == queries.size(),
			"find_paths with %d workers answers each query as find_path alone does" % workers,
			"%d of %d the same" % [same, queries.size()]
		)
		_check(
			Vector2i(graph.searches, graph.failures) - searched == counted and graph.filter == null,
			"and counts searches and failures as they do, and restores the filter (%d workers)" % workers,
			"%s against %s" % [Vector2i(graph.searches, graph.failures) - searched, counted]
		)

	# The spawner: off finds inline as it always did; on queues and answers at the end of the think.
	var limits := _limits()
	limits.spawn_snap_radius = 3.0
	var spawners: Array[DotNpcSpawner] = [_spawner(limits), _spawner(limits)]
	spawners[1].path_workers = 4
	var paths: Array = [[], []]

	for s in 2:
		spawners[s].set_nav_data(data)
		for i in 12:
			var npc := spawners[s].spawn(&"walker", (queries[i] as DotNpcNavGraph.PathQuery).from)
			var path := DotNpcPath.new()
			spawners[s].path_toward(npc, path, (queries[i] as DotNpcNavGraph.PathQuery).to)
			paths[s].append(path)

	_check(
		(paths[0] as Array).any(func(p: DotNpcPath) -> bool: return not p.is_empty()),
		"path_workers 0 searches inside path_toward, as before"
	)

	var threaded := DotParallel.resolve_workers(4) > 0
	_check(
		not threaded or (paths[1] as Array).all(func(p: DotNpcPath) -> bool: return p.is_empty()),
		"path_workers 4 queues the repath instead of searching inline",
		"skipped: this machine has no worker threads" if not threaded else ""
	)

	spawners[1].answer_paths()
	var agree := 0

	for i in 12:
		var a: DotNpcPath = paths[0][i]
		var b: DotNpcPath = paths[1][i]
		if a.points == b.points and a.partial == b.partial:
			agree += 1

	_check(agree == 12, "and after answer_paths every path equals the inline one", "%d of 12" % agree)

	# Web, or no threads: the same setting resolves to 0 and path_toward searches inline.
	DotPlatform._kind = DotPlatform.Kind.WEB
	var web_workers := DotParallel.resolve_workers(4)
	var web_npc := spawners[1].spawn(&"walker", Vector3(-10, 0, -10))
	var web_path := DotNpcPath.new()
	spawners[1].path_toward(web_npc, web_path, Vector3(10, 0, 10))
	DotPlatform._kind = -1
	_check(web_workers == 0, "on the web sv_threads_npc resolves to 0 workers")
	_check(not web_path.is_empty(), "and path_toward finds the path inline there")
	_check(spawners[1].describe().has("path_workers"), "describe() reports the path workers")

	for s in spawners:
		s.queue_free()
	_done()
