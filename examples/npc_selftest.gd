extends "res://examples/selftest/replication_tests.gd"

## Proves the population holds, the senses commit, the graph paths and nothing leaks.
## [b]The tests that matter are the ones no count can pass by accident[/b]: a target that flickers between two people,
## a graph that joins a walkway to the floor below, a reclaim that deletes what is chasing someone. Real nodes, real tree.


const CHECKS := 242 + 23 + 15 + 6 + 3 + 4 + 4 + 3 + 13 + 4 + 2 + 11 + 3 + 3 + 3 + 2 + 3 + 2 + 3 + 2 + 11 + 4 + 2 + 2 + 8 + 5 + 8 + 2

## Sections entered against sections that ran to their last line. A runtime error inside a section aborts that
## function and nothing says so; a section that bailed early after a failed guard counts as unfinished on purpose.
## CHECKS is the other half; see docs/testing.md.
const SECTIONS := 44

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
	_test_nav_one_way()
	_test_nav_cover()
	_test_path()
	await _test_senses_basics()
	_test_senses_commitment()
	_test_senses_grace()
	_test_senses_cap()
	_test_senses_pruning()
	_test_senses_workers()
	_test_senses_quiet()
	_test_senses_blind_and_smoke()
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
	_test_think_split()
	_test_drive()
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
	# The total the section counter cannot be: a runtime error aborts a section that had
	# already announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


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

	_nav_scale_native_vs_script(nav, graph, rng)
	_done()


func _nav_scale_native_vs_script(nav: DotNpcNavData, graph: DotNpcNavGraph, rng: RandomNumberGenerator) -> void:
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

	_smoothing_around_wall(graph, from, to)
	_done()


## Smoothing must not graze a corner closer than a body (0.32 m) even though a sample only has to be near a point.
func _smoothing_keeps_a_body_off_corners() -> void:
	var post := AABB(Vector3(-0.5, 0, -0.5), Vector3(1, 2, 1))
	var builder := DotNpcNavBuilder.new()
	builder.spacing = 1.0
	builder.add_floor(AABB(Vector3(-6, 0, -6), Vector3(12, 0, 12)), 0.0)
	builder.add_obstacle(post)
	var graph := DotNpcNavGraph.new(builder.build(&"post", "digest"))
	graph.straight_width_ratio = 0.5
	var closest := INF
	var paths := 0

	for z in range(-4, 5):
		var path := graph.find_smooth_path(Vector3(-4.5, 0, z + 0.3), Vector3(4.5, 0, -z - 0.3), 2.0)
		paths += 1 if not path.is_empty() else 0

		for k in path.size() - 1:
			for i in 21:
				var p := path[k].lerp(path[k + 1], i / 20.0)
				var d := Vector2(maxf(absf(p.x) - 0.5, 0.0), maxf(absf(p.z) - 0.5, 0.0)).length()
				closest = minf(closest, d)

	_check(paths > 0 and closest >= 0.32, "a smoothed leg passes a corner at least a body away", "%d paths, closest %.2f" % [paths, closest])

	# The leg memo must follow the ratio: a graph that smoothed at 0.75 and was then set to 0.5 answers as a fresh 0.5 one.
	var warm := DotNpcNavGraph.new(builder.build(&"post", "digest"))
	var fresh := DotNpcNavGraph.new(builder.build(&"post", "digest"))
	fresh.straight_width_ratio = 0.5
	var same := true

	for z in range(-4, 5):
		var a := Vector3(-4.5, 0, z + 0.3)
		var b := Vector3(4.5, 0, -z - 0.3)
		warm.straight_width_ratio = 0.75
		warm.find_smooth_path(a, b, 2.0)
		warm.straight_width_ratio = 0.5
		same = same and warm.find_smooth_path(a, b, 2.0) == fresh.find_smooth_path(a, b, 2.0)

	_check(same, "changing the straight-width ratio drops the remembered legs", "")


func _smoothing_around_wall(graph: DotNpcNavGraph, from: Vector3, to: Vector3) -> void:
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

	_smoothing_keeps_a_body_off_corners()

	var two := PackedVector3Array([from, to])
	_check(
		graph.smooth_path(two).size() == 2,
		"a path with nothing to remove comes back unchanged"
	)


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

	_nav_filter_flags(from, to)
	_done()


func _nav_filter_flags(from: Vector3, to: Vector3) -> void:
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

	await _senses_on_floor(senses)
	_done()


func _senses_on_floor(senses: DotNpcSenses) -> void:
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


const SPLIT_TICKS := 2000

## The gather/decide/apply split: the same 2000-tick hash of every brain's intents and the NPCs' places with decide inline, again,
## and on two workers with DotParallel.verify. Applying in NPC order is what makes the three agree.
func _test_drive() -> void:
	_section("a player's drive")
	var drive := DotNpcDrive.new()
	_check(not drive.active and drive.wish_velocity(5.0) == Vector3.ZERO, "idle: inactive and no wish")
	drive.grab(&"p1")
	drive.feed(Vector2(0, 1), 0.0, 1)
	_check(drive.active and drive.wish_velocity(5.0).is_equal_approx(Vector3(0, 0, -5)), "forward at yaw 0 is -Z", str(drive.wish_velocity(5.0)))
	drive.feed(Vector2(0, 1), PI * 0.5, 1)
	_check(drive.wish_velocity(5.0).is_equal_approx(Vector3(-5, 0, 0)), "a quarter turn left walks -X", str(drive.wish_velocity(5.0)))
	drive.feed(Vector2(3, 4), 0.0, 1)
	_check(is_equal_approx(drive.move.length(), 1.0), "diagonal intent is clamped to 1")
	_check(drive.take_pressed() == 1 and drive.take_pressed() == 0, "a press is an edge, taken once")
	drive.feed(Vector2.ZERO, 0.0, 0)
	drive.feed(Vector2.ZERO, 0.0, 1)
	_check(drive.take_pressed() == 1, "and a release then a press is a new edge")

	var brain := DotNpcBrain.new()
	brain.drive = drive
	brain.think(0.1)
	_check(brain.age > 0.0, "a driven brain still ages")
	drive.release()
	_check(not drive.active and drive.holder == &"", "release clears the hold")
	_done()


func _test_think_split() -> void:
	_section("split think")

	var verify_before := DotParallel.verify
	DotParallel.verify = true
	var failures_before := DotParallel.verify_failures
	var off := _split_run(0)
	var off_again := _split_run(0)
	var on := _split_run(2)
	DotParallel.verify = verify_before

	_check(off[1] == 24 * SPLIT_TICKS, "every split brain applied every tick", "%d applies" % off[1])
	_check(off[0] != 0 and off[2] > 1, "the hash covers distinct intents", "%s" % [off])
	_check(off[0] == off_again[0], "off against off: the same hash of 2000 ticks", "%d vs %d" % [off[0], off_again[0]])
	_check(on[0] == off[0], "workers 2 against off: the same hash",
		"%d vs %d%s" % [on[0], off[0], "" if DotParallel.resolve_workers(2) > 0 else " (no threads here: inline)"])
	_check(DotParallel.verify_failures == failures_before, "and verify found no task that differs between runs")
	_done()


## Returns [hash, applies, distinct histories] of one scripted run.
func _split_run(workers: int) -> Array:
	var limits := _limits()
	limits.world_budget = 0
	limits.per_kind_cap = 0
	var spawner := _spawner(limits)
	var def := DotNpcDef.make(&"splitter", BODY)
	def.brain_script_path = "res://fixtures/split_brain.gd"
	def.max_health = 100.0
	def.require_line_of_sight = false
	spawner.catalogue.add(def)
	spawner.think_workers = workers
	var brains: Array = []

	for i in 24:
		var npc := spawner.spawn(&"splitter", Vector3(i * 1.5 - 18.0, 0, (i % 5) * 3.0 - 6.0))
		if npc != null:
			brains.append(npc.brain)

	for t in SPLIT_TICKS:
		spawner.tick(0.016)

	var h := 0
	var applies := 0
	var distinct := {}

	for b in brains:
		h = hash([h, b.history, snappedf(b.npc.position().x, 0.001), snappedf(b.npc.position().z, 0.001)])
		applies += b.ticks
		distinct[b.history] = true

	spawner.queue_free()
	return [h, applies, distinct.size()]
