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
const BRAIN := "res://fixtures/walker_brain.gd"

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()

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
	_test_path()
	_test_senses_basics()
	_test_senses_commitment()
	_test_senses_grace()
	_test_spawning()
	_test_authority()
	_test_world_budget()
	_test_per_kind_cap()
	_test_spawn_interval()
	_test_navigable_spawn()
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

	get_tree().quit(1 if _failed > 0 else 0)


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
	print("definitions")

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


func _test_catalogue() -> void:
	print("catalogue")

	var cat := _catalogue()
	_check(cat.size() == 4, "a catalogue holds what was added", "%d" % cat.size())
	_check(cat.get_npc(&"walker") != null, "and finds by id")
	_check(cat.get_npc(&"nothing") == null, "and answers null for what is not there")
	var categories := cat.categories()
	_check(
		categories.size() == 3 and categories[0] == "npc" and categories[2] == "zombie",
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


func _test_limits() -> void:
	print("limits")

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


# --- Navigation --------------------------------------------------------------

func _test_nav_data() -> void:
	print("navigation data")

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


func _test_nav_builder() -> void:
	print("navigation builder")

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


func _test_nav_graph() -> void:
	print("navigation graph")

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


func _test_path() -> void:
	print("path following")

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


# --- Senses ------------------------------------------------------------------

func _test_senses_basics() -> void:
	print("senses")

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


func _test_senses_commitment() -> void:
	print("senses: commitment")

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


func _test_senses_grace() -> void:
	print("senses: the grace period")

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


# --- Spawning ----------------------------------------------------------------

func _test_spawning() -> void:
	print("spawning")

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


func _test_authority() -> void:
	print("authority")

	var client := DotNpcSpawner.new()
	client.catalogue = _catalogue()
	client.limits = _limits()
	client.authoritative = false
	_world.add_child(client)

	_check(client.spawn(&"walker", Vector3.ZERO) == null, "a client may not spawn")
	_check(client.world_count() == 0, "and nothing appeared")

	client.queue_free()


func _test_world_budget() -> void:
	print("the world budget")

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


func _test_per_kind_cap() -> void:
	print("the per-kind cap")

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


func _test_spawn_interval() -> void:
	print("the spawn interval")

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


func _test_navigable_spawn() -> void:
	print("navigable spawns")

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


func _test_brains() -> void:
	print("brains")

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


func _test_damage() -> void:
	print("damage")

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


func _test_reclaim() -> void:
	print("reclaim")

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


func _test_cleanup() -> void:
	print("cleanup")

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


func _test_no_leaked_nodes() -> void:
	print("no leaks")

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


# --- Replication --------------------------------------------------------------

func _test_net_sync() -> void:
	print("replication")

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


## The receiving half of a replication, without dot-net in the project.
class _NetProbe:
	extends RefCounted

	var net_x: float = 0.0
	var net_y: float = 0.0
	var net_z: float = 0.0
	var net_yaw: int = 0
	var net_health: int = 0
	var net_state: int = 0
