extends "res://examples/selftest/definition_tests.gd"
## Nav data, builder, scale and graph sections.

func _test_nav_data() -> void:
	_section("navigation data")

	var nav := DotNpcNavData.new()
	_check(not nav.validate().ok, "empty nav data is refused")

	nav.map_id = &"test"
	nav.add_point(Vector3.ZERO)
	nav.add_point(Vector3(2, 0, 0))
	nav.connect_points(0, 1)
	_check(
		not nav.validate().ok,
		"and so is nav data with no digest",
		"nothing could then tell whether it was stale"
	)

	nav.source_digest = DotNpcNavData.digest_of([1.0, 2.0])
	_check(nav.validate().ok, "with a digest it validates")
	_check(nav.matches(DotNpcNavData.digest_of([1.0, 2.0])), "and matches its source")
	_check(
		not nav.matches(DotNpcNavData.digest_of([1.0, 2.01])),
		"and stops matching when a constant moves by a centimetre",
		"var_to_str rather than str, or the float would round to the same string"
	)

	var cache := nav.to_cache_bytes()
	_check(DotNpcNavData.from_cache_bytes(cache) != null, "a current-version cache loads")
	var old := bytes_to_var(cache.slice(4).decompress(cache.decode_u32(0), FileAccess.COMPRESSION_GZIP)) as Dictionary
	old["format"] = DotNpcNavData.FORMAT_VERSION - 1
	var raw := var_to_bytes(old)
	var old_bytes := PackedByteArray([0, 0, 0, 0]) + raw.compress(FileAccess.COMPRESSION_GZIP)
	old_bytes.encode_u32(0, raw.size())
	_check(DotNpcNavData.from_cache_bytes(old_bytes) == null, "a cache from an older version is rejected, so it is rebuilt")

	_check(not nav.connect_points(0, 9).ok, "an edge off the end is refused")

	var round_tripped := DotNpcNavData.from_dictionary(nav.to_dictionary())
	_check(
		round_tripped.point_count() == 2 and round_tripped.edge_count() == 1,
		"and nav data survives a round trip"
	)

	# Two equal ways round a block; a place marked bad is gone round by everyone until it expires.
	var diamond := DotNpcNavData.new()
	diamond.map_id = &"diamond"
	diamond.source_digest = "d"
	for p: Vector3 in [Vector3(0, 0, 0), Vector3(4, 0, 3), Vector3(4, 0, -3), Vector3(8, 0, 0)]:
		var _i := diamond.add_point(p)
	var _e := [diamond.connect_points(0, 1), diamond.connect_points(1, 3), diamond.connect_points(0, 2), diamond.connect_points(2, 3)]
	var dg := DotNpcNavGraph.new(diamond)
	var _warm := dg.find_path(Vector3.ZERO, Vector3(8, 0, 0), 1.0)
	var bad_at := dg.mark_bad(Vector3(4, 0, 3), 10.0, 6.0, 0.5)
	var around := dg.find_path(Vector3.ZERO, Vector3(8, 0, 0), 1.0)
	_check(bad_at == 1 and dg.bad_count() == 1 and around.has(Vector3(4, 0, -3)) and not around.has(Vector3(4, 0, 3)), "a point marked bad is gone round")
	dg.expire_bad(11.0)
	_check(dg.bad_count() == 0, "and forgiven when its time is up")
	_done()


func _test_nav_builder() -> void:
	_section("navigation builder")

	var builder := DotNpcNavBuilder.new()
	builder.spacing = 2.0
	builder.add_floor(AABB(Vector3(-10, 0, -10), Vector3(20, 0, 20)), 0.0)
	builder.add_obstacle(AABB(Vector3(-1, 0, -10), Vector3(2, 3, 14)))

	var nav := builder.build(&"test_map", "digest")

	_check(nav.point_count() > 0, "a floor becomes points", "%d" % nav.point_count())
	_check(nav.edge_count() > 0, "and neighbours become edges", "%d" % nav.edge_count())
	_check(
		not nav.is_navigable(Vector3(0, 0, 0), 0.5),
		"and no point sits inside a wall"
	)

	# A cancelled build has no result, and the same builder then builds again from scratch.
	var cancelled := DotNpcNavBuilder.new()
	cancelled.spacing = 2.0
	cancelled.generate_cover = true
	cancelled.add_floor(AABB(Vector3(-10, 0, -10), Vector3(20, 0, 20)), 0.0)
	cancelled.add_obstacle(AABB(Vector3(-1, 0, -10), Vector3(2, 3, 14)))
	cancelled.begin(&"cancel_map", "digest")
	cancelled.step(0.0001)
	cancelled.cancel()
	_check(not cancelled.step(0.0) and not cancelled.is_done() and cancelled.result() == null, "a cancelled build is not done and has no result")
	_check(cancelled.is_cancelled(), "and reports cancelled")
	cancelled.clearance = 1.5
	cancelled.cover_range = 3.0
	var rebuilt := cancelled.build(&"cancel_map", "digest")
	_check(rebuilt != null and rebuilt.point_count() > 0 and not cancelled.is_cancelled(), "begin resets the cancel and the same builder builds again")
	var fresh := DotNpcNavBuilder.new()
	fresh.spacing = 2.0
	fresh.generate_cover = true
	fresh.clearance = 1.5
	fresh.cover_range = 3.0
	fresh.add_floor(AABB(Vector3(-10, 0, -10), Vector3(20, 0, 20)), 0.0)
	fresh.add_obstacle(AABB(Vector3(-1, 0, -10), Vector3(2, 3, 14)))
	_check(
		fresh.build(&"cancel_map", "digest").point_count() == rebuilt.point_count(),
		"and honours a changed clearance (obstacle cells are rebuilt)"
	)

	var two_storey := DotNpcNavBuilder.new()
	two_storey.spacing = 2.0
	two_storey.add_floor(AABB(Vector3(-4, 0, -4), Vector3(8, 0, 8)), 0.0)
	two_storey.add_floor(AABB(Vector3(-4, 0, -4), Vector3(8, 0, 8)), 6.0)

	var stacked := two_storey.build(&"stacked", "digest")
	var graph := DotNpcNavGraph.new(stacked)

	_check(
		graph.find_path(Vector3(0, 0, 0), Vector3(0, 6, 0), 2.0).is_empty(),
		"a walkway over a floor is not joined to it",
		"the single commonest thing wrong with a generated graph"
	)

	two_storey.add_link(Vector3(3, 0, 3), Vector3(3, 6, 3))
	var linked := DotNpcNavGraph.new(two_storey.build(&"stacked", "digest"))

	_check(
		not linked.find_path(Vector3(0, 0, 0), Vector3(0, 6, 0), 2.0).is_empty(),
		"and a declared link is what joins two storeys"
	)
	_nav_builder_links()
	_nav_builder_slopes()
	_done()


## Links, ladders, floors laid from different corners and edge sampling.
func _nav_builder_links() -> void:
	# A ladder stands in a wall, away from the grid: a wide reach finds the floor either side, and only at its own height.
	var shaft := DotNpcNavBuilder.new()
	shaft.spacing = 2.0
	shaft.add_floor(AABB(Vector3(-4, 0, -4), Vector3(8, 0, 8)), 0.0)
	shaft.add_floor(AABB(Vector3(-4, 0, -4), Vector3(8, 0, 8)), 6.0)
	shaft.add_link(Vector3(9, 0.1, 0), Vector3(9, 6, 0))
	var near_only := DotNpcNavGraph.new(shaft.build(&"shaft", "digest"))
	_check(near_only.find_path(Vector3(0, 0, 0), Vector3(0, 6, 0), 2.0).is_empty(), "a link end beyond twice the spacing finds no point")
	var reach := DotNpcNavBuilder.new()
	reach.spacing = 2.0
	reach.add_floor(AABB(Vector3(-4, 0, -4), Vector3(8, 0, 8)), 0.0)
	reach.add_floor(AABB(Vector3(-4, 0, -4), Vector3(8, 0, 8)), 6.0)
	reach.add_link(Vector3(7, 3, 0), Vector3(7, 6, 0), 0, 6.0, 1.0)
	_check(DotNpcNavGraph.new(reach.build(&"reach", "digest")).find_path(Vector3(0, 0, 0), Vector3(0, 6, 0), 2.0).is_empty(),
		"a link given a reach still takes only points near the height of its end (no floor within 1 m of y 3)")
	var tall := DotNpcNavBuilder.new()
	tall.spacing = 2.0
	tall.add_floor(AABB(Vector3(-4, 0, -4), Vector3(8, 0, 8)), 0.0)
	tall.add_floor(AABB(Vector3(-4, 0, -4), Vector3(8, 0, 8)), 6.0)
	tall.add_link(Vector3(7, 0.1, 0), Vector3(7, 6, 0), 0, 6.0, 1.0)
	_check(not DotNpcNavGraph.new(tall.build(&"tall", "digest")).find_path(Vector3(0, 0, 0), Vector3(0, 6, 0), 2.0).is_empty(),
		"and a link given a reach joins the floors from outside the grid")

	# A room, a doorway and a street, each laid from its own corner so their grids are offset by a fraction of
	# a step. Rounding positions to the grid merged the room's last row with the street's first and split the door.
	var offset := DotNpcNavBuilder.new()
	offset.spacing = 1.0
	offset.clearance = 0.35
	offset.add_floor(AABB(Vector3(-4.9, 0, -13.9), Vector3(9.8, 0, 7.8)), 0.0)
	offset.add_floor(AABB(Vector3(-1.1, 0, -6.3), Vector3(2.2, 0, 0.8)), 0.0)
	offset.add_floor(AABB(Vector3(-8.9, 0, -6.0), Vector3(17.8, 0, 16.0)), 0.0)
	offset.add_obstacle(AABB(Vector3(-5.2, 0, -6.0), Vector3(4.0, 3, 0.2)))
	offset.add_obstacle(AABB(Vector3(1.2, 0, -6.0), Vector3(4.0, 3, 0.2)))
	var street := offset.build(&"offset", "digest")
	var joined := DotNpcNavGraph.new(street)
	_check(not joined.find_path(Vector3(0, 0, -10), Vector3(0, 0, 5), 1.5).is_empty(),
		"floors laid from different corners still join through a doorway")

	var crowded := 0
	for i in street.points.size():
		for j in range(i + 1, street.points.size()):
			if street.points[i].distance_to(street.points[j]) < 0.5:
				crowded += 1
	_check(crowded == 0, "and overlapping floors still do not put two points in one place", "%d pairs" % crowded)

	# Edge sampling: a short diagonal must be sampled, a ramp edge must not hit a lower box.
	var sampled := DotNpcNavBuilder.new()
	sampled.spacing = 1.0
	sampled.clearance = 0.35
	sampled.add_obstacle(AABB(Vector3(-58.18, 3.54, 58.48), Vector3(0.3, 0.46, 0.3)))
	sampled.add_obstacle(AABB(Vector3(-36.5, 0, -1), Vector3(1, 2.78, 2)))
	_check(sampled._crosses_obstacle(Vector3(-57.95, 3.58, 58.05), Vector3(-57.45, 3.58, 58.75)),
		"an edge shorter than one sample step is still tested (a diagonal clipping a prop's corner is dropped)")
	_check(not sampled._crosses_obstacle(Vector3(-34.75, 2.89, -0.45), Vector3(-35.95, 3.39, -0.45)),
		"a ramp edge climbing past a box just under its feet is kept")
	_check(not sampled._crosses_obstacle(Vector3(-34.75, 2.89, 3.0), Vector3(-35.95, 3.39, 3.0)),
		"and an edge clear of every box is kept")


## Slope points, floors a gap apart and narrow walkways.
func _nav_builder_slopes() -> void:
	# A 35 degree hillside beside a flat yard: slope points climb it, a floor's step would not.
	var hillside := PackedVector3Array()
	var cliff := PackedVector3Array()
	for x in range(0, 10):
		for z in range(0, 4):
			hillside.append(Vector3(x + 0.5, (x + 0.5) * 0.7, z + 0.5))
			cliff.append(Vector3(x + 0.5, (x + 0.5) * 2.0, z + 10.5))
	var hill := DotNpcNavBuilder.new()
	hill.spacing = 1.0
	hill.add_floor(AABB(Vector3(-4, 0, 0), Vector3(4, 0, 4)), 0.35)
	hill.add_points(hillside, 1.0)
	hill.add_points(cliff, 1.0)
	var hill_graph := DotNpcNavGraph.new(hill.build(&"hill", "digest"))
	_check(not hill_graph.find_path(Vector3(-3.5, 0.35, 2), Vector3(9.5, 6.65, 2), 1.0).is_empty(),
		"slope points climb a hillside and join the floor at its foot")
	_check(hill_graph.find_path(Vector3(0.5, 1.0, 10.5), Vector3(5.5, 11.0, 10.5), 1.0).is_empty(),
		"and a slope steeper than their limit stays apart")
	var flat := DotNpcNavBuilder.new()
	flat.spacing = 1.0
	for p in hillside:
		flat.add_floor(AABB(Vector3(p.x - 0.5, 0, p.z - 0.5), Vector3(1, 0, 1)), p.y)
	_check(DotNpcNavGraph.new(flat.build(&"steps", "digest")).find_path(Vector3(0.5, 0.35, 2), Vector3(9.5, 6.65, 2), 1.0).is_empty(),
		"while the same hill as floors is a step too far per point")

	# Two rooms whose floors stop 1.5 m apart: islands until bridge_gap joins them, and a wall between them still holds.
	var bridge_goal := Vector3(3.5, 0, 0.5)
	for case in [[0.0, false, false], [2.5, false, true], [2.5, true, false]]:
		var rooms := DotNpcNavBuilder.new()
		rooms.spacing = 1.0
		rooms.bridge_gap = case[0]
		rooms.add_floor(AABB(Vector3(-3, 0, 0), Vector3(3, 0, 3)), 0.0)
		rooms.add_floor(AABB(Vector3(1.5, 0, 0), Vector3(3, 0, 3)), 0.0)
		if case[1]:
			rooms.add_obstacle(AABB(Vector3(0.6, 0, -1), Vector3(0.2, 3, 6)))
		var rooms_graph := DotNpcNavGraph.new(rooms.build(&"rooms", "digest"))
		_check(rooms_graph.find_path(Vector3(-2.5, 0, 0.5), bridge_goal, 1.0).is_empty() != case[2],
			"bridge_gap %s%s: rooms 1.5 m apart are %s" % [case[0], " with a wall between" if case[1] else "", "joined" if case[2] else "separate"])

	# A walkway cut into 0.4 m strips holds no grid point unless centre_narrow_floors puts one in the middle of each.
	for centred in [false, true]:
		var strips := DotNpcNavBuilder.new()
		strips.spacing = 1.0
		strips.centre_narrow_floors = centred
		for k in 6:
			strips.add_floor(AABB(Vector3(0, 0, k * 0.4), Vector3(3, 0, 0.4)), 0.0)
		strips.add_floor(AABB(Vector3(0, 0, -3), Vector3(3, 0, 3)), 0.0)
		strips.add_floor(AABB(Vector3(0, 0, 2.4), Vector3(3, 0, 3)), 0.0)
		_check(DotNpcNavGraph.new(strips.build(&"strips", "digest")).find_path(Vector3(1.5, 0, -2.5), Vector3(1.5, 0, 4.9), 1.0).is_empty() != centred,
			"centre_narrow_floors %s: rooms joined by a walkway of 0.4 m strips are %s" % [centred, "joined" if centred else "separate"])


func _test_nav_graph() -> void:
	_section("navigation graph")

	# A corridor bent round a wall: the straight line is blocked and the path is not.
	var builder := DotNpcNavBuilder.new()
	builder.spacing = 2.0
	builder.add_floor(AABB(Vector3(-12, 0, -12), Vector3(24, 0, 24)), 0.0)
	builder.add_obstacle(AABB(Vector3(-2, 0, -12), Vector3(4, 4, 20)))

	var graph := DotNpcNavGraph.new(builder.build(&"bent", "digest"))
	var from := Vector3(-8, 0, 0)
	var to := Vector3(8, 0, 0)
	var path := graph.find_path(from, to, 3.0)

	_check(not path.is_empty(), "a path is found around a wall", "%d points" % path.size())
	_check(
		path[0] == from and path[path.size() - 1] == to,
		"and it begins and ends where the caller actually is",
		"or an NPC walks back to the nearest node before setting off"
	)

	var straight := from.distance_to(to)
	var walked := 0.0

	for i in range(path.size() - 1):
		walked += path[i].distance_to(path[i + 1])

	_check(
		walked > straight,
		"and it is longer than the straight line, because it goes round",
		"%.1f m against %.1f m" % [walked, straight]
	)

	var blocked := false

	for i in range(path.size() - 1):
		var steps := 8
		for s in steps:
			var p := path[i].lerp(path[i + 1], float(s) / float(steps))
			if AABB(Vector3(-2, 0, -12), Vector3(4, 4, 20)).has_point(p):
				blocked = true

	_check(not blocked, "and no leg of it passes through the wall")

	var nowhere := graph.find_path(from, Vector3(500, 0, 500), 3.0)
	_check(nowhere.is_empty(), "a goal off the graph gives no path at all")
	_done()


## Whether any leg of a path enters a box.
func _path_enters(path: PackedVector3Array, box: AABB, samples: int = 12) -> bool:
	for i in range(path.size() - 1):
		for s in samples + 1:
			if box.has_point(path[i].lerp(path[i + 1], float(s) / float(samples))):
				return true
	return false


## Whether any waypoint of a path is inside a box.
## Not [method _path_enters]: a diagonal grid routes round a box by clipping its corner between two
## waypoints, so asking about the waypoints is the question the pathfinder answered.
func _path_visits(path: PackedVector3Array, box: AABB) -> bool:
	for point in path:
		if box.has_point(point):
			return true
	return false


func _path_length(path: PackedVector3Array) -> float:
	var total := 0.0
	for i in range(path.size() - 1):
		total += path[i].distance_to(path[i + 1])
	return total
