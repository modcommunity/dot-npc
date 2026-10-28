extends "res://examples/selftest/nav_tests.gd"
## Smoothing, filter, partial path, cover and path sections.


func _test_nav_partial() -> void:
	_section("navigation partial paths")

	# Two rooms with nothing joining them.
	var builder := DotNpcNavBuilder.new()
	builder.spacing = 2.0
	builder.generate_cover = false
	builder.add_floor(AABB(Vector3(-14, 0, -6), Vector3(10, 0, 12)), 0.0)
	builder.add_floor(AABB(Vector3(6, 0, -6), Vector3(10, 0, 12)), 0.0)

	var graph := DotNpcNavGraph.new(builder.build(&"split", "digest"))
	var from := Vector3(-12, 0, 0)
	var to := Vector3(12, 0, 0)

	_check(graph.find_path(from, to, 3.0).is_empty(), "an unreachable goal gives no path")
	_check(not graph.last_partial, "and does not claim to be partial")

	var partial := graph.find_path(from, to, 3.0, true)
	_check(not partial.is_empty(), "unless a partial path was asked for")
	_check(graph.last_partial, "which says so")

	var end := partial[partial.size() - 1]
	_check(
		end.distance_to(to) > 1.0,
		"a partial path stops short of the goal",
		"%.1f m short" % end.distance_to(to)
	)
	_check(
		end.distance_to(to) < from.distance_to(to),
		"but closer to it than where the NPC started"
	)
	_check(
		end.x < 6.0,
		"and it does not step across the gap it could not path over",
		"ended at x=%.1f" % end.x
	)

	var reachable := graph.find_path(from, Vector3(-8, 0, 4), 3.0, true)
	_check(not reachable.is_empty(), "a reachable goal is unaffected")
	_check(not graph.last_partial, "and is not reported as partial")

	# The shortcut for a goal in another piece of the graph must end where a full search does.
	# A neutral filter turns the shortcut off (it is filter-blind), so the search runs.
	graph.filter = DotNpcNavFilter.neutral()
	var searched := graph.find_path(from, to, 3.0, true)
	graph.filter = null
	_check(not searched.is_empty() and searched[searched.size() - 1].distance_to(end) < 0.01,
		"the shortcut ends where a full search does",
		"%s against %s" % [str(end), str(searched[searched.size() - 1]) if not searched.is_empty() else "nothing"])

	# Walked to the end of a partial path, a follower waits for the interval before searching
	# again; forty zombies at a shut gate searching every tick was most of a server's second.
	var follower := DotNpcPath.new()
	follower.set_points(partial, 10.0, to)
	follower.partial = true
	follower.index = partial.size()
	_check(not follower.needs_repath(10.5, to, 1.5, 2.5),
		"a partial path walked out does not search again at once")
	_check(follower.needs_repath(11.6, to, 1.5, 2.5),
		"but does once the interval is up")
	_done()


func _test_nav_cover() -> void:
	_section("navigation cover")

	var wall := AABB(Vector3(-1, 0, -10), Vector3(2, 3, 20))
	var builder := DotNpcNavBuilder.new()
	builder.spacing = 2.0
	builder.add_floor(AABB(Vector3(-12, 0, -12), Vector3(24, 0, 24)), 0.0)
	builder.add_obstacle(wall)

	var nav := builder.build(&"cover", "digest")

	_check(nav.cover_count() > 0, "the generator records cover beside a wall",
		"%d spots" % nav.cover_count())

	var all_beside := true
	for i in nav.cover_count():
		if absf(nav.cover_positions[i].x) > 4.0:
			all_beside = false
	_check(all_beside, "and only beside it, not in the middle of the room")

	var all_horizontal := true
	for n in nav.cover_normals:
		if absf(n.y) > 0.001:
			all_horizontal = false
	_check(
		all_horizontal,
		"a cover normal is horizontal: the floor is an obstacle directly below and "
		+ "hiding behind the ground is not a thing"
	)

	# A threat to the west. The spot to take is east of the wall, with its normal
	# pointing back at the wall — which is the direction of the threat.
	var index := nav.best_cover(Vector3(6, 0, 0), Vector3(-9, 0, 0), 20.0)
	_check(index >= 0, "cover is found from a threat")
	_check(
		nav.cover_positions[index].x > 0.0,
		"on the far side of the wall from the threat",
		"x = %.1f" % nav.cover_positions[index].x
	)

	var west := nav.best_cover(Vector3(-6, 0, 0), Vector3(9, 0, 0), 20.0)
	_check(
		west >= 0 and nav.cover_positions[west].x < 0.0,
		"and the other way round when the threat moves"
	)

	var far := nav.best_cover(Vector3(6, 0, 0), Vector3(-9, 0, 0), 1.0)
	_check(far < 0, "nothing within reach means no cover, not the best of a bad lot")

	var open := DotNpcNavBuilder.new()
	open.spacing = 2.0
	open.add_floor(AABB(Vector3(-12, 0, -12), Vector3(24, 0, 24)), 0.0)
	_check(
		open.build(&"open", "digest").cover_count() == 0,
		"a room with nothing in it has nowhere to hide"
	)

	var no_hide := DotNpcNavBuilder.new()
	no_hide.spacing = 2.0
	no_hide.add_floor(
		AABB(Vector3(-12, 0, -12), Vector3(24, 0, 24)), 0.0,
		DotNpcNavData.AREA_GROUND, DotNpcNavData.Flag.NO_HIDE
	)
	no_hide.add_obstacle(wall)
	_check(
		no_hide.build(&"nohide", "digest").cover_count() == 0,
		"and a floor marked NO_HIDE generates none"
	)

	_check(
		nav.cover_position_from(Vector3(6, 0, 0), Vector3(-9, 0, 0)).x > 0.0,
		"the position helper answers the same question"
	)
	_done()


func _test_path() -> void:
	_section("path following")

	var path := DotNpcPath.new()
	var points := PackedVector3Array([
		Vector3(0, 0, 0), Vector3(4, 0, 0), Vector3(8, 0, 0)
	])
	path.set_points(points, 0.0, Vector3(8, 0, 0))

	_check(path.current() == Vector3(4, 0, 0), "it starts at the second point")
	_check(
		path.advance(Vector3(3.5, 0, 0)) == Vector3(8, 0, 0),
		"and advances once the NPC is close enough"
	)

	var on_a_slope := DotNpcPath.new()
	on_a_slope.set_points(points, 0.0, Vector3(8, 0, 0))
	_check(
		on_a_slope.advance(Vector3(4.0, 3.0, 0.0)) == Vector3(8, 0, 0),
		"and arriving is judged horizontally",
		"a waypoint under an NPC's feet is never reached by a 3D distance test"
	)

	_check(
		not path.needs_repath(0.5, Vector3(8, 0, 0), 1.5, 2.5),
		"a path to a goal that has not moved is kept"
	)
	_check(
		path.needs_repath(0.5, Vector3(20, 0, 0), 1.5, 2.5),
		"a goal that ran forces a repath"
	)
	_check(
		path.needs_repath(9.0, Vector3(8, 0, 0), 1.5, 2.5),
		"and so does the interval, for a world that changed around a still goal"
	)
	_done()
