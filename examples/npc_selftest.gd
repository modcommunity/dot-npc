extends Node

## Proves the population holds, the senses commit, the graph paths and nothing leaks.
##
## [codeblock]
## godot --headless --path . res://examples/npc_selftest.tscn
## [/codeblock]
##
## [b]The tests that matter are the ones no count can pass by accident.[/b] A
## population budget is easy to assert and easy to get right; what breaks an NPC layer
## in front of players is a target that flickers between two people standing together,
## a graph that joins a walkway to the floor below it, and a reclaim that deletes the
## thing chasing somebody the moment they back through a doorway. All three are here,
## with real nodes in a real tree, because a limit that counted a dictionary would pass
## while leaking bodies.

const BODY := "res://fixtures/npc_body.tscn"
const BODY_2D := "res://fixtures/npc_body_2d.tscn"
const BRAIN := "res://fixtures/walker_brain.gd"

const CHECKS := 203

## Sections entered against sections that ran to their last line, and against this. A
## runtime error inside a section aborts that function and nothing says so; a section that
## bailed out early after a failed guard is counted as not finished on purpose. The CHECKS
## total is the other half — see docs/testing.md.
const SECTIONS := 29

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var _world: Node3D = null


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
	_test_limits()
	_test_nav_data()
	_test_nav_builder()
	_test_nav_graph()
	_test_nav_smoothing()
	_test_nav_filter()
	_test_nav_partial()
	_test_nav_cover()
	_test_path()
	_test_senses_basics()
	_test_senses_commitment()
	_test_senses_grace()
	_test_target_since()
	_test_spawning()
	_test_spawning_2d()
	_test_authority()
	_test_world_budget()
	_test_per_kind_cap()
	_test_spawn_interval()
	_test_navigable_spawn()
	_test_spawner_pathing()
	_test_brains()
	_test_damage()
	_test_reclaim()
	_test_cleanup()
	# Awaited. It waits two frames for `queue_free` to actually run, and an un-awaited
	# call to a coroutine returns at its first `await` — so the leak check would be
	# scheduled to finish after `get_tree().quit()` and would never report anything.
	# It looked like a passing suite that was quietly one check short.
	await _test_no_leaked_nodes()
	_test_net_sync()

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


func _section(title: String) -> void:
	_entered += 1
	print(title)


## A section reached its last line. See [constant SECTIONS].
func _done() -> void:
	_completed += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		var line := what if detail == "" else "%s (%s)" % [what, detail]
		_failures.append(line)
		print("  FAIL  %s" % line)


# --- Builders ----------------------------------------------------------------

func _catalogue() -> DotNpcCatalogue:
	var cat := DotNpcCatalogue.new()

	var walker := DotNpcDef.make(&"walker", BODY)
	walker.brain_script_path = BRAIN
	walker.category = &"zombie"
	walker.max_health = 100.0
	walker.sight_range = 30.0
	walker.hearing_range = 10.0
	walker.require_line_of_sight = false
	walker.meta = {"speed": 4.0}
	cat.add(walker)

	var brute := DotNpcDef.make(&"brute", BODY)
	brute.brain_script_path = BRAIN
	brute.category = &"zombie"
	brute.cost = 8
	brute.max_health = 400.0
	brute.require_line_of_sight = false
	cat.add(brute)

	var critter := DotNpcDef.make(&"critter", BODY)
	critter.category = &"wildlife"
	critter.faction = &"neutral"
	critter.cost = 1
	critter.max_health = 10.0
	critter.require_line_of_sight = false
	cat.add(critter)

	# A 2D NPC, in the same catalogue as the 3D ones. A [DotNpcDef] deliberately says
	# nothing about dimension, so a catalogue holding both is a legitimate thing for a
	# game with a 2D world to have, and the spawner has to pick the right entry point
	# rather than infer one.
	var swarmer := DotNpcDef.make(&"swarmer", BODY_2D)
	swarmer.brain_script_path = BRAIN
	swarmer.category = &"swarm"
	swarmer.max_health = 40.0
	swarmer.sight_range = 300.0
	# [b]Off, and it has to be for a 2D NPC.[/b] There is no 3D physics world to cast
	# through, and [method DotNpcSenses._has_line_of_sight] answers "clear" rather than
	# blinding it — but saying so in the definition is what makes that a decision rather
	# than a fallback nobody noticed.
	swarmer.require_line_of_sight = false
	swarmer.meta = {"speed": 90.0}
	cat.add(swarmer)

	var broken := DotNpcDef.make(&"broken", BODY)
	broken.brain_script_path = "res://fixtures/not_a_brain.gd"
	broken.require_line_of_sight = false
	cat.add(broken)

	return cat


func _spawner(limits: DotNpcLimits = null) -> DotNpcSpawner:
	var spawner := DotNpcSpawner.new()
	spawner.catalogue = _catalogue()
	spawner.limits = limits if limits != null else _limits()
	spawner.authoritative = true
	_world.add_child(spawner)
	return spawner


## Limits with the rate limiter off, because almost every test spawns several NPCs in
## one tick and would otherwise be measuring the cooldown rather than what it is about.
func _limits() -> DotNpcLimits:
	var limits := DotNpcLimits.new()
	limits.spawn_interval = 0.0
	limits.require_navigable_spawn = false
	return limits


func _candidate(
	id: StringName, at: Vector3, faction: StringName = &"player", loudness: float = 0.0
) -> DotNpcSenses.Candidate:
	return DotNpcSenses.Candidate.new(id, at, faction, loudness)


## An NPC standing at the origin, facing -Z, with no spawner behind it.
##
## Built by hand rather than spawned, so the perception tests are about perception and
## not about whether a scene loaded.
func _loose_npc(def: DotNpcDef, at: Vector3 = Vector3.ZERO) -> DotNpcInstance:
	var body := Node3D.new()
	_world.add_child(body)
	body.global_position = at

	var npc := DotNpcInstance.new()
	npc.def = def
	npc.node = body
	npc.instance_id = body.get_instance_id()
	npc.health = def.max_health

	return npc


# --- Definitions -------------------------------------------------------------

func _test_definitions() -> void:
	_section("definitions")

	var walker := DotNpcDef.make(&"walker", BODY)
	_check(walker.validate().ok, "a definition validates")
	_check(walker.is_local(), "and ships in the build when it has no content id")

	var nameless := DotNpcDef.new()
	_check(not nameless.validate().ok, "one with no id is refused")

	var by_class := DotNpcDef.make(&"walker", BODY)
	by_class.brain_script_path = "ZombieBrain"
	_check(
		not by_class.validate().ok,
		"a brain named by class rather than by path is refused"
	)

	var round_tripped := DotNpcDef.from_dictionary(walker.to_dictionary())
	_check(round_tripped.id == walker.id, "a definition survives a round trip")
	_check(
		round_tripped.sight_half_angle_deg == walker.sight_half_angle_deg,
		"including its perception"
	)

	walker.meta = {"speed": 4.0}
	var copied := walker.to_dictionary()
	(copied["meta"] as Dictionary)["speed"] = 99.0
	_check(
		float(walker.meta["speed"]) == 4.0,
		"and its meta is copied out, not handed out",
		"a Dictionary is a reference; this is the aliasing bug dot-timer had five of"
	)
	_done()


func _test_catalogue() -> void:
	_section("catalogue")

	var cat := _catalogue()
	_check(cat.size() == 5, "a catalogue holds what was added", "%d" % cat.size())
	_check(cat.get_npc(&"walker") != null, "and finds by id")
	_check(cat.get_npc(&"nothing") == null, "and answers null for what is not there")
	var categories := cat.categories()
	_check(
		categories.size() == 4 and categories[0] == "npc" and categories[3] == "zombie",
		"categories are the enabled ones, sorted",
		str(categories)
	)
	_check(cat.in_faction(&"neutral").size() == 1, "and a faction can be listed")

	var rejected := PackedStringArray()
	var reloaded := DotNpcCatalogue.from_dictionary({
		"npcs": [
			{"id": "good", "scene": BODY},
			{"id": "", "scene": BODY},
			{"id": "also_good", "scene": BODY},
		]
	}, rejected)

	_check(
		reloaded.size() == 2 and rejected.size() == 1,
		"one bad entry does not condemn the file",
		"%d kept, %d rejected" % [reloaded.size(), rejected.size()]
	)
	_done()


func _test_limits() -> void:
	_section("limits")

	var limits := DotNpcLimits.new()
	_check(limits.validate().ok, "the defaults are usable")

	limits.per_kind_cap = 500
	limits.world_budget = 96
	_check(
		not limits.validate().ok,
		"a per-kind cap above the world budget is refused",
		"it could never be reached, which reads as the cap being ignored"
	)

	var configured := DotNpcLimits.new()
	configured.apply_dictionary({"world_budget": 12})
	_check(
		configured.world_budget == 12,
		"and it is a DotConfig, so a file or a command line can retune it"
	)
	_done()


# --- Navigation --------------------------------------------------------------

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

	_check(not nav.connect_points(0, 9).ok, "an edge off the end is refused")

	var round_tripped := DotNpcNavData.from_dictionary(nav.to_dictionary())
	_check(
		round_tripped.point_count() == 2 and round_tripped.edge_count() == 1,
		"and nav data survives a round trip"
	)
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
	_done()


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


# --- Smoothing, filters, partial paths and cover ----------------------------

## Whether any leg of a path enters a box.
func _path_enters(path: PackedVector3Array, box: AABB, samples: int = 12) -> bool:
	for i in range(path.size() - 1):
		for s in samples + 1:
			if box.has_point(path[i].lerp(path[i + 1], float(s) / float(samples))):
				return true
	return false


## Whether any waypoint of a path is inside a box.
##
## Deliberately not [method _path_enters], which samples the segments too. A grid
## graph with diagonals routes round a box-shaped area by clipping its corner between
## two waypoints — the NPC never stands in the water and the straight line between two
## steps grazes it. Asking about the waypoints is asking the question the pathfinder
## actually answered.
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
	# Aligned with the ground grid on purpose: both floors start on an odd metre, so
	# their cells coincide and the first one to claim a cell keeps it. Two floors
	# whose grids are offset produce two interleaved sets of points a metre apart and
	# the strip stops being a barrier at all — which is not a bug in the builder, and
	# is exactly the mistake a generator makes once.
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


# --- Senses ------------------------------------------------------------------

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
	_done()


func _test_senses_commitment() -> void:
	_section("senses: commitment")

	var senses := DotNpcSenses.new()
	var def := DotNpcDef.make(&"seer", BODY)
	def.require_line_of_sight = false
	def.sight_half_angle_deg = 180.0

	var npc := _loose_npc(def)

	var near := _candidate(&"near", Vector3(0, 0, -10))
	var also_near := _candidate(&"also", Vector3(0, 0, -10.4))

	_check(
		senses.update_target(npc, [near, also_near], 0.0) == &"near",
		"it commits to the nearest"
	)

	var flips := 0
	var last := npc.target_id

	for tick in 40:
		# Two candidates a fraction of a metre apart, swapping which is marginally
		# nearer every tick. This is the classic broken NPC: without the switch ratio
		# it turns back and forth for ever and never reaches either.
		near.position = Vector3(0, 0, -10.0 - (0.5 if tick % 2 == 0 else 0.0))
		also_near.position = Vector3(0, 0, -10.0 - (0.0 if tick % 2 == 0 else 0.5))

		var now := senses.update_target(npc, [near, also_near], float(tick) * 0.1)

		if now != last:
			flips += 1

		last = now

	_check(flips == 0, "and does not flicker between two people standing together",
		"%d switches in 40 ticks" % flips)

	var much_nearer := _candidate(&"much", Vector3(0, 0, -2))
	_check(
		senses.update_target(npc, [near, much_nearer], 5.0) == &"much",
		"but does switch to something decisively closer"
	)
	_done()


## `target_since` moves when a commitment does, and not while one is held.
##
## [b]This is the field dot-npc-ai's reaction time is measured against, and the reason it
## exists.[/b] `engaged_at` is refreshed on every pass in which a target is perceived —
## which is right for a reclaim and fatal for a reaction: a timer measured against it can
## never elapse for an NPC that can currently see somebody, so every branch behind such a
## gate never runs. Nothing errors; the bot just never acts.
func _test_target_since() -> void:
	_section("commitment time")

	var senses := DotNpcSenses.new()
	var npc := _loose_npc(_catalogue().get_npc(&"walker"))

	var one := _candidate(&"one", Vector3(0, 0, -6))
	senses.update_target(npc, [one], 10.0, 8)

	_check(npc.target_id == &"one", "an NPC commits to somebody")
	_check(
		is_equal_approx(npc.target_since, 10.0),
		"and records WHEN it committed (%.1f)" % npc.target_since
	)

	# Ten more seconds of seeing exactly the same person.
	for step in range(10):
		senses.update_target(npc, [one], 11.0 + float(step), 8)

	_check(
		is_equal_approx(npc.target_since, 10.0),
		"which does not move while it keeps seeing them (%.1f)" % npc.target_since,
		"a reaction time measured against a field that moves every tick never elapses"
	)
	_check(
		npc.engaged_at > npc.target_since,
		"while `engaged_at` does, because that is what a reclaim asks about",
		"engaged %.1f, since %.1f" % [npc.engaged_at, npc.target_since]
	)

	# Somebody much closer. A new commitment, so the clock starts again.
	var two := _candidate(&"two", Vector3(0, 0, -1))
	senses.update_target(npc, [one, two], 30.0, 8)

	_check(npc.target_id == &"two", "a much nearer rival takes the commitment")
	_check(
		is_equal_approx(npc.target_since, 30.0),
		"and the clock starts again (%.1f)" % npc.target_since
	)
	_done()


func _test_senses_grace() -> void:
	_section("senses: the grace period")

	var senses := DotNpcSenses.new()
	senses.commitment_grace = 3.0

	var def := DotNpcDef.make(&"seer", BODY)
	def.require_line_of_sight = false
	def.sight_half_angle_deg = 180.0

	var npc := _loose_npc(def)
	var player := _candidate(&"p", Vector3(0, 0, -5))

	senses.update_target(npc, [player], 0.0)
	_check(npc.target_id == &"p", "it acquires a target")

	_check(
		senses.update_target(npc, [], 1.0) == &"p",
		"and keeps chasing one that stepped through a doorway",
		"otherwise a doorway is a perfect escape and it turns away mid-swing"
	)
	_check(
		senses.update_target(npc, [], 4.0) == &"",
		"and gives up once the grace expires"
	)

	senses.update_target(npc, [player], 5.0)
	var rival := _candidate(&"q", Vector3(0, 0, -3))
	_check(
		senses.update_target(npc, [rival], 5.1) == &"q",
		"a perceived rival ends the grace immediately",
		"ignoring the player hitting it to chase one that left is worse than either"
	)
	_done()


# --- Spawning ----------------------------------------------------------------

func _test_spawning() -> void:
	_section("spawning")

	var spawner := _spawner()
	var npc := spawner.spawn(&"walker", Vector3(1, 0, 2))

	_check(npc != null, "an NPC spawns")
	_check(npc.is_alive(), "and is alive")
	_check(npc.node.global_position == Vector3(1, 0, 2), "and is where it was asked for")
	_check(npc.health == 100.0, "and starts on its definition's health")
	_check(spawner.world_count() == 1, "and the spawner knows about it")
	_check(spawner.count_of(&"walker") == 1, "and counts it against its kind")

	_check(spawner.spawn(&"nothing", Vector3.ZERO) == null, "an unknown id is refused")

	var group := spawner.spawn_group(&"walker", Vector3.ZERO, 5, 3.0)
	_check(group.size() == 5, "a group spawns", "%d" % group.size())

	var positions := {}
	for one in group:
		positions[str(one.position().snapped(Vector3.ONE * 0.01))] = true

	_check(positions.size() == 5, "and no two of them are in the same place")

	spawner.queue_free()
	_done()


## The same spawner, into a 2D world.
##
## [b]The point is that everything except the placement is shared.[/b] The catalogue, the
## budget, the per-kind cap, the perception, the commitment, the reclaim and the brain are
## the same code — so what is worth checking is the mapping onto the plane, and the one
## thing a mixed catalogue makes possible: asking for a 2D NPC through the 3D entry point,
## and the reverse. Both must be refused rather than half-built, because a scene that is
## instantiated and then rejected is a leaked node nothing reports.
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

	# [b]The plane is XZ, and this is the check that says so.[/b] Everything inside this
	# addon measures a 3D distance — the senses, the steering, the navigation — and on a
	# plane where one component never moves that IS the 2D distance. Get the mapping
	# wrong and a sight range of 300 is a sight range of nothing, silently.
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


func _test_authority() -> void:
	_section("authority")

	var client := DotNpcSpawner.new()
	client.catalogue = _catalogue()
	client.limits = _limits()
	client.authoritative = false
	_world.add_child(client)

	_check(client.spawn(&"walker", Vector3.ZERO) == null, "a client may not spawn")
	_check(client.world_count() == 0, "and nothing appeared")

	client.queue_free()
	_done()


func _test_world_budget() -> void:
	_section("the world budget")

	var limits := _limits()
	limits.world_budget = 10
	limits.per_kind_cap = 0

	var spawner := _spawner(limits)

	# Cost 8, so one fits and a second does not — the budget is in cost, not in bodies.
	_check(spawner.spawn(&"brute", Vector3.ZERO) != null, "a heavy NPC fits")
	_check(spawner.spawn(&"brute", Vector3.ZERO) == null, "a second does not")
	_check(
		spawner.spawn(&"walker", Vector3.ZERO) != null,
		"but a cheap one still does",
		"the budget is counted in cost, not in bodies"
	)
	_check(spawner.world_cost() == 9, "and the cost adds up", "%d" % spawner.world_cost())

	spawner.queue_free()
	_done()


func _test_per_kind_cap() -> void:
	_section("the per-kind cap")

	var limits := _limits()
	limits.world_budget = 100
	limits.per_kind_cap = 3

	var spawner := _spawner(limits)

	for i in 5:
		spawner.spawn(&"walker", Vector3.ZERO)

	_check(spawner.count_of(&"walker") == 3, "a kind stops at its cap",
		"%d" % spawner.count_of(&"walker"))
	_check(
		spawner.spawn(&"critter", Vector3.ZERO) != null,
		"and another kind is unaffected",
		"a budget alone lets a director spend it all on whatever is cheapest"
	)

	spawner.remove(spawner.all_npcs()[0].instance_id)
	_check(
		spawner.spawn(&"walker", Vector3.ZERO) != null,
		"and removing one makes room for another"
	)

	spawner.queue_free()
	_done()


func _test_spawn_interval() -> void:
	_section("the spawn interval")

	var limits := _limits()
	limits.spawn_interval = 0.5

	var spawner := _spawner(limits)

	_check(spawner.spawn(&"walker", Vector3.ZERO, &"director") != null, "one spawns")
	_check(
		spawner.spawn(&"walker", Vector3.ZERO, &"director") == null,
		"a second in the same tick is refused"
	)
	_check(
		spawner.spawn(&"walker", Vector3.ZERO, &"other") != null,
		"but a different spawner is not held up by it"
	)

	for i in 40:
		spawner.tick(1.0 / 60.0)

	_check(
		spawner.spawn(&"walker", Vector3.ZERO, &"director") != null,
		"and the wait passes in simulated time",
		"a wall clock would let a player who lags the server spawn faster"
	)

	spawner.queue_free()
	_done()


func _test_navigable_spawn() -> void:
	_section("navigable spawns")

	var limits := _limits()
	limits.require_navigable_spawn = true
	limits.spawn_snap_radius = 3.0

	var spawner := _spawner(limits)

	_check(
		spawner.spawn(&"walker", Vector3(500, 0, 500)) != null,
		"with no navigation at all, every spawn is legal",
		"or the setting would mean 'no NPCs on a map with no nav data'"
	)

	var builder := DotNpcNavBuilder.new()
	builder.spacing = 2.0
	builder.add_floor(AABB(Vector3(-10, 0, -10), Vector3(20, 0, 20)), 0.0)
	spawner.set_nav_data(builder.build(&"test", "digest"))

	_check(spawner.has_nav(), "navigation is adopted")
	_check(
		spawner.spawn(&"walker", Vector3(0, 0, 0)) != null,
		"a spawn on the graph is allowed"
	)
	_check(
		spawner.spawn(&"walker", Vector3(200, 0, 200)) == null,
		"and one nowhere near it is refused",
		"an NPC off the graph stands still for ever, which reads as a broken brain"
	)

	var snapped := spawner.spawn(&"walker", Vector3(0.4, 0.0, 0.4))
	_check(
		snapped != null and snapped.position().distance_to(Vector3(0.4, 0, 0.4)) < 3.0,
		"and one just off a point is snapped onto it"
	)

	spawner.set_nav_data(null)
	_check(not spawner.has_nav(), "and navigation can be cleared on a map change")

	spawner.queue_free()
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

	spawner.queue_free()
	_done()


func _test_brains() -> void:
	_section("brains")

	var spawner := _spawner()
	var npc := spawner.spawn(&"walker", Vector3.ZERO)

	_check(npc.brain != null, "a definition naming a brain gets one")
	_check(npc.brain is DotNpcBrain, "and it is a brain")

	var broken := spawner.spawn(&"broken", Vector3.ZERO)
	_check(broken != null, "an NPC whose brain is not a brain still spawns",
		"deleting it would hide which script was wrong")
	_check(
		broken.brain == null,
		"but it is not given one",
		"or the tick after the spawn calls think() on something with no such method"
	)

	var critter := spawner.spawn(&"critter", Vector3.ZERO)
	_check(critter.brain == null, "and an NPC that names no brain simply has none")

	# One tick with a candidate in front of it: the brain should think and steer.
	spawner.set_candidates([_candidate(&"p", Vector3(0, 0, -8))])

	for i in 8:
		spawner.tick(1.0 / 60.0)

	_check(int(npc.brain.get(&"thinks")) > 0, "and a brain is ticked by the spawner")
	_check(npc.has_target(), "and its NPC perceives what the host handed it")
	_check(
		npc.position().distance_to(Vector3(0, 0, -8)) < 8.0,
		"and it moved toward it",
		"%.2f m away" % npc.position().distance_to(Vector3(0, 0, -8))
	)

	spawner.queue_free()
	_done()


func _test_damage() -> void:
	_section("damage")

	var spawner := _spawner()
	var npc := spawner.spawn(&"walker", Vector3.ZERO)
	var deaths: Array[StringName] = []
	var removals: Array[StringName] = []

	# Captured Arrays rather than counters. A GDScript lambda captures locals BY
	# VALUE, so a counter incremented in a handler stays zero outside it and the test
	# reports a failure for a signal that fired perfectly.
	spawner.died.connect(func(_n: DotNpcInstance, by: StringName) -> void:
		deaths.append(by))
	spawner.removed.connect(func(_n: DotNpcInstance, reason: StringName) -> void:
		removals.append(reason))

	_check(spawner.damage(npc.instance_id, 30.0, &"p") == 30.0, "damage lands")
	_check(npc.health == 70.0, "and health comes off")
	_check(int(npc.brain.get(&"damage_taken")) == 30, "and the brain is told")

	_check(spawner.heal(npc.instance_id, 1000.0) == 30.0, "healing stops at the maximum")

	_check(spawner.damage(npc.instance_id, 500.0, &"p") == 100.0,
		"an overkill takes exactly what was left")
	_check(deaths.size() == 1 and deaths[0] == &"p", "and it dies, naming who did it")
	_check(
		removals.size() == 1 and removals[0] == DotNpcSpawner.REASON_KILLED,
		"and is removed as killed rather than as tidied away",
		"a game with only `removed` would award a kill for a reclaim"
	)
	_check(spawner.world_count() == 0, "and it is gone")
	_check(spawner.damage(npc.instance_id, 10.0) == 0.0, "and cannot be hurt again")

	var by_combat := spawner.spawn(&"walker", Vector3.ZERO)
	_check(
		spawner.report_death(by_combat.instance_id, &"combat"),
		"a game whose health is dot-combat's reports the death directly"
	)
	_check(deaths.size() == 2, "and lands on the same signal")

	spawner.queue_free()
	_done()


func _test_reclaim() -> void:
	_section("reclaim")

	var limits := _limits()
	limits.reclaim_distance = 40.0
	limits.reclaim_grace = 2.0

	var spawner := _spawner(limits)
	var near := spawner.spawn(&"walker", Vector3(0, 0, -5))
	var far := spawner.spawn(&"walker", Vector3(0, 0, -400))

	spawner.set_candidates([_candidate(&"p", Vector3.ZERO)])

	for i in 10:
		spawner.tick(1.0 / 60.0)

	_check(spawner.world_count() == 2, "nothing is reclaimed inside the grace period",
		"otherwise a player backing through a doorway deletes what is chasing them")

	for i in 200:
		spawner.tick(1.0 / 60.0)

	_check(not far.is_alive(), "one nobody can see is reclaimed once the grace passes")
	_check(near.is_alive(), "and one beside a player is not")

	spawner.set_candidates([])

	var alone := spawner.spawn(&"walker", Vector3(0, 0, -900))

	for i in 400:
		spawner.tick(1.0 / 60.0)

	_check(
		alone.is_alive(),
		"and an empty server reclaims nothing",
		"or a dedicated server between rounds empties the wave it just built"
	)

	spawner.queue_free()
	_done()


func _test_cleanup() -> void:
	_section("cleanup")

	var spawner := _spawner()

	for i in 4:
		spawner.spawn(&"walker", Vector3.ZERO, &"alice")

	spawner.spawn(&"walker", Vector3.ZERO, &"bob")

	_check(spawner.npcs_of(&"alice").size() == 4, "an owner's NPCs are tracked")
	_check(spawner.owner_left(&"alice") == 4, "and go when they do")
	_check(spawner.world_count() == 1, "and nobody else's went with them")

	spawner.limits.clean_up_on_leave = false
	_check(spawner.owner_left(&"bob") == 0, "a server that keeps them, keeps them")
	_check(spawner.world_count() == 1, "and they are still there")
	_check(
		spawner.npcs_of(&"bob").is_empty(),
		"but disowned, so a departed player's budget is not held for ever"
	)

	_check(spawner.clear_all() == 1, "and everything can be cleared")

	spawner.queue_free()
	_done()


func _test_no_leaked_nodes() -> void:
	_section("no leaks")

	var holder := Node3D.new()
	_world.add_child(holder)

	var spawner := DotNpcSpawner.new()
	spawner.catalogue = _catalogue()
	spawner.limits = _limits()
	spawner.authoritative = true
	spawner.world_ref = DotNodeRef.of_self()
	holder.add_child(spawner)

	for i in 12:
		spawner.spawn(&"walker", Vector3.ZERO)

	# A real count of the tree, not of the dictionary. A budget that counted its own
	# bookkeeping would pass while leaking bodies, which is the whole failure mode.
	var before := spawner.get_child_count()
	_check(before == 12, "twelve NPCs are twelve nodes", "%d" % before)

	spawner.clear_all()
	await get_tree().process_frame
	await get_tree().process_frame

	_check(spawner.get_child_count() == 0, "and clearing them frees every one",
		"%d left" % spawner.get_child_count())

	holder.queue_free()
	_done()


# --- Replication --------------------------------------------------------------

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
