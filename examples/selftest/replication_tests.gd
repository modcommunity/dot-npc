extends "res://examples/selftest/brain_tests.gd"

## Replication, limb and gore sections, and the 2D spawning section.


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

	_net_apply_checks(spawner, probe)
	spawner.queue_free()
	_done()


func _net_apply_checks(spawner: DotNpcSpawner, probe: _NetProbe) -> void:
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

	node.queue_free()


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
	# c80b948: an empty rest read is not cached, so a host fills the dictionary through store_rest_points.
	var arm := DotNpcLimbs.new()
	arm.rest_model = "synthetic://limbs_regression"
	body.add_child(arm)
	var arm_def: Dictionary = defs["armL"]
	_check(arm.points_of(arm_def).is_empty(), "an arm with no rest data has no points")
	DotNpcLimbs.store_rest_points(arm.rest_model, {&"armL": Vector3(-0.5, 1.4, 0)})
	_check(arm.points_of(arm_def).size() >= 1, "points_of on an arm returns points once the host stores rest points after the first read")
	_check(arm.points_of(arm_def)[0].is_equal_approx(body.global_transform * Vector3(-0.5, 1.4, 0)), "the stored arm origin is the first point")
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

	_spawning_2d_refusals(spawner, world_2d)
	world_2d.queue_free()
	_done()


func _spawning_2d_refusals(spawner: DotNpcSpawner, world_2d: Node2D) -> void:
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
