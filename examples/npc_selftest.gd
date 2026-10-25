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
const CHOOSER := "res://fixtures/chooser_brain.gd"

const CHECKS := 238 + 23 + 15 + 6 + 3 + 4 + 4 + 3 + 13

## Sections entered against sections that ran to their last line, and against this. A
## runtime error inside a section aborts that function and nothing says so; a section that
## bailed out early after a failed guard is counted as not finished on purpose. The CHECKS
## total is the other half — see docs/testing.md.
const SECTIONS := 37

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
	_test_senses_workers()
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
	_test_stable_seeds()
	_test_brains_are_released()
	_test_damage()
	_test_reclaim()
	_test_cleanup()
	# Awaited. It waits two frames for `queue_free` to actually run, and an un-awaited
	# call to a coroutine returns at its first `await` — so the leak check would be
	# scheduled to finish after `get_tree().quit()` and would never report anything.
	# It looked like a passing suite that was quietly one check short.
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


const PROFILE_BASE := "user://npc_profile_selftest"


func _pw(rel: String, text: String) -> void:
	var path := PROFILE_BASE.path_join(rel)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _rm(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_rm(dir.path_join(d))
	DirAccess.remove_absolute(dir)


func _test_profiles() -> void:
	_section("profiles")
	_rm(PROFILE_BASE)
	DotLog.set_level(DotLog.Level.FATAL)
	_pw("addons/dot-npc/npc/walker.yml", "name: Walker\nscene: %s\nbrain: %s\ncategory: zombie\nhealth: 100\nhearing: 10\nlos: false\nmeta:\n  speed: 4.0\nextra:\n  groan:\n    pitch: 0.8\nmenu:\n  sort: 2\n  icon: res://walker.png\n" % [BODY, BRAIN])
	_pw("addons/dot-npc/npc/brute.yml", "extends: walker\ncost: 8\nhealth: 400\nweight: heavy\nmenu:\n  sort: 1\n  category: zombie/big\n")
	_pw("addons/dot-npc/npc/ghost.yml", "extends: walker\nmenu:\n  hidden: true\n")
	_pw("game/mygame/npc/walker.yml", "health: 150\nextra:\n  groan:\n    volume: 3\n")
	_pw("addons/dot-npc/npc/broken.yml", "scene: [unclosed\n  : x: :\n")
	var roots := PackedStringArray([PROFILE_BASE])

	var addon_only := DotNpcProfiles.make_set("", roots)
	var res := DotNpcProfiles.load_def(addon_only, "walker")
	var def: DotNpcDef = res.value if res.ok else null
	var ref: DotNpcDef = _catalogue().get_npc(&"walker")
	_check(def != null, "a profile loads into a definition", "" if res.ok else res.error.message)
	if def == null:
		return
	_check(
		def.to_dictionary() == ref.to_dictionary().merged({"extra": {"groan": {"pitch": 0.8}}, "menu": {"sort": 2, "icon": "res://walker.png"}}),
		"and equals the code-built definition apart from extra and menu",
		str(def.to_dictionary())
	)
	_check(def.id == &"walker" and def.category == &"zombie" and def.validate().ok, "its id is the file name")

	var game_set := DotNpcProfiles.make_set("mygame", roots)
	var over := DotNpcProfiles.load_def(game_set, "walker").value as DotNpcDef
	_check(over.max_health == 150.0 and over.hearing_range == 10.0, "a game overrides a key and keeps the addon's others")
	_check(over.extra["groan"]["pitch"] == 0.8 and over.extra["groan"]["volume"] == 3, "extra is merged and handed to the brain")
	_check(def.max_health == 100.0, "and another set still sees the addon value")

	var brute := DotNpcProfiles.load_def(game_set, "brute").value as DotNpcDef
	_check(brute.weight == DotNpcDef.Weight.HEAVY and brute.cost == 8 and brute.max_health == 400.0, "extends and weight by name")
	_check(brute.category == &"zombie/big", "menu.category sets the category")

	var ids := game_set.list_ids()
	_check(ids == PackedStringArray(["broken", "brute", "ghost", "walker"]), "ids are listed from the directories", str(ids))
	var entries := DotNpcProfiles.menu_entries(game_set)
	_check(entries.size() == 2 and entries[0]["id"] == "brute" and entries[1]["id"] == "walker", "the menu is sorted and skips hidden and broken", str(entries))
	_check(entries[0]["category"] == "zombie/big" and entries[1]["icon"] == "res://walker.png", "with category and icon")
	_check(DotNpcProfiles.menu_entries(game_set, true).size() == 3, "hidden ones can be asked for")

	var bad := DotNpcProfiles.load_def(game_set, "broken")
	_check(not bad.ok and bad.error.code == DotError.CODE_PARSE, "a bad yml is a parse error", "" if bad.ok else bad.error.code)
	_check(not bad.ok and "broken" in bad.error.message, "that names the file")
	_pw("game/mygame/npc/typo.yml", "scene: x\nhealht: 5\n")
	var typo := DotNpcProfiles.load_def(game_set, "typo")
	_check(not typo.ok and typo.error.code == DotError.CODE_INVALID, "an unknown key is refused")
	game_set.clear_cache()
	var errors := PackedStringArray()
	var cat := DotNpcProfiles.to_catalogue(game_set, errors)
	_check(cat.size() == 3 and errors.size() == 2, "a catalogue keeps the good ones and reports the bad", "%d kept, %d errors" % [cat.size(), errors.size()])

	var plain := DotNpcDef.from_dictionary({"id": "old", "scene": BODY, "health": 20})
	_check(plain.extra.is_empty() and plain.menu.is_empty() and plain.max_health == 20.0, "a dictionary without extra still loads")
	_check(not plain.to_dictionary().has("extra") and not plain.to_dictionary().has("menu"), "and serialises without the new keys")
	var rt := DotNpcDef.from_dictionary(def.to_dictionary())
	_check(rt.extra == def.extra and rt.menu == def.menu, "extra survives a round trip")
	var coded := DotNpcDef.make(&"c", BODY)
	_check(coded.validate().ok and coded.extra.is_empty(), "code-built definitions are untouched")
	_check(_catalogue().size() == 5, "and the catalogue built from code is intact")
	_check(DotNpcProfiles.schema().size() == 20, "the schema lists the common keys")
	_check(DotNpcProfiles.profile_schemas()["npc"]["schema"].size() == 20, "profile_schemas names the npc kind for the validator")
	# A set and its cached profiles point at each other; clear them or they leak at exit.
	for set_to_clear in [addon_only, game_set]:
		set_to_clear.clear_cache()
	DotLog.set_level(DotLog.Level.ERROR)
	_rm(PROFILE_BASE)
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

	# A room, a doorway and a street, each laid from its own corner, so their grids are offset
	# by a fraction of a step. Rounding positions to the grid used to merge the room's last row
	# with the street's first and split the graph at the door (game-zombie-zone's start room).
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
	_done()


## A campaign-sized map: the indexes added for it must answer what a scan does, and fast.
##
## [b]Equality against brute force, not "it returned something".[/b] A bucket index that
## missed the neighbouring bucket would still find a point, just not the nearest one, and
## an NPC snapping to the second-nearest point paths from the wrong side of a wall.
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

	# The native search (AStar3D) against the script A* it replaced: the same length of path
	# for random pairs, with and without a filter that makes some ground dearer, and much
	# faster. Same length rather than same points, because two routes of equal cost may be
	# taken either way round.
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

	# Standing on a real floor, with line of sight on. The sight line used to start at the
	# feet, ON the floor, and hit it at distance zero: every NPC on a floor was blind.
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


## Ranking on worker threads commits every NPC exactly as the inline pass does.
func _test_senses_workers() -> void:
	_section("senses on workers")

	var limits := _limits()
	limits.sense_period_ticks = 1
	limits.sense_candidate_cap = 4
	limits.per_kind_cap = 100
	limits.burst_cap = 100
	var spawner := _spawner(limits)
	var npcs: Array = []

	for i in 40:
		npcs.append(spawner.spawn(&"critter", Vector3(float(i % 8) * 3.0, 0, float(i / 8) * 3.0)))

	var list: Array = []

	for i in 60:
		list.append(_candidate(StringName("c%d" % i),
			Vector3(float(i % 10) * 2.5 - 2.0, 0, float(i / 10) * 2.5 - 2.0)))

	spawner.set_candidates(list)
	spawner.tick(1.0 / 60.0)
	var inline := PackedStringArray()

	for npc in npcs:
		inline.append(String(npc.target_id))
		npc.target_id = &""

	spawner.sense_workers = 2
	spawner.tick(1.0 / 60.0)
	var threaded := PackedStringArray()

	for npc in npcs:
		threaded.append(String(npc.target_id))

	_check(inline.count("") < 5, "nearly every NPC commits (the rest face away)", ",".join(inline))
	_check(inline == threaded, "and ranking on workers commits each to the same target",
		"%s against %s" % [",".join(inline), ",".join(threaded)])
	_check(DotParallel.resolve_workers(2) == 0 or int(DotParallel.describe()["labels"].get("npc.senses", {}).get("pooled", 0)) > 0,
		"the pass ran on the pool", str(DotParallel.describe()["labels"]))
	spawner.queue_free()
	_done()


## The candidate cap keeps the nearest within reach, never the first in list order.
func _test_senses_cap() -> void:
	_section("senses: the candidate cap")

	var senses := DotNpcSenses.new()
	var def := DotNpcDef.make(&"seer", BODY)
	def.require_line_of_sight = false
	def.sight_half_angle_deg = 180.0
	def.sight_range = 30.0

	var npc := _loose_npc(def)
	var list: Array = []

	for i in 30:
		list.append(_candidate(StringName("far%d" % i), Vector3(0, 0, -20.0 - 0.1 * i)))

	list.append(_candidate(&"near", Vector3(0, 0, -3)))
	_check(senses.update_target(npc, list, 0.0, 8) == &"near",
		"past the cap the nearest is still seen", "got %s" % npc.target_id)

	var out_of_reach: Array = []

	for i in 30:
		out_of_reach.append(_candidate(StringName("gone%d" % i), Vector3(0, 0, -100.0 - i)))

	out_of_reach.append(_candidate(&"late", Vector3(0, 0, -25)))
	var fresh := _loose_npc(def)
	_check(senses.update_target(fresh, out_of_reach, 0.0, 8) == &"late",
		"candidates out of reach take no slot of the cap")

	var held := _loose_npc(def)
	held.target_id = &"far29"
	held.target_seen_at = 0.0
	var crowd: Array = list.slice(0, 30)

	for i in 10:
		crowd.append(_candidate(StringName("mid%d" % i), Vector3(0, 0, -15.0 - 0.1 * i)))

	senses.update_target(held, crowd, 1.0, 8)
	_check(held.target_id == &"far29" and is_equal_approx(held.target_seen_at, 1.0),
		"the committed target is tested even past the cap", "got %s" % held.target_id)
	_check(senses.update_target(npc, list, 2.0, 0) == &"near",
		"a cap of 0 still tests the nearest one")
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

	spawner.queue_free()
	_done()


func _test_brains() -> void:
	_section("brains")

	var spawner := _spawner()
	# Every kind's scene and brain loaded and held before the first spawn, once.
	var warmed := spawner.warm()
	_check(warmed >= 2 and spawner.warm() == 0, "warm() loads every kind's scene and brain once and holds them", "%d loaded" % warmed)
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

	# Facing from somewhere a metre cannot change (a body fallen or flung far out) is skipped,
	# not handed to look_at, which refuses it with an error once a think.
	var far_body := npc.node as Node3D
	var was_at := far_body.global_position
	var was_turned := far_body.global_rotation
	far_body.global_position = Vector3(3.0e7, 0.0, 3.0e7)
	(npc.brain as DotNpcBrain).face(Vector3(1, 0, 1))
	_check(far_body.global_rotation.is_equal_approx(was_turned), "face() from a position a metre cannot change does nothing")
	far_body.global_position = was_at

	# One tick with a candidate in front of it: the brain should think and steer.
	spawner.set_candidates([_candidate(&"p", Vector3(0, 0, -8))])

	for i in 8:
		spawner.tick(1.0 / 60.0)

	_check(int(npc.brain.get(&"thinks")) > 0, "and a brain is ticked by the spawner")
	_check(npc.has_target(), "and its NPC perceives what the host handed it")
	_check(
		spawner.candidates().size() == 1 and spawner.candidates()[0].id == &"p"
			and spawner.candidates().size() == spawner.candidate_count(),
		"candidates() returns what set_candidates was handed"
	)
	_check(
		npc.position().distance_to(Vector3(0, 0, -8)) < 8.0,
		"and it moved toward it",
		"%.2f m away" % npc.position().distance_to(Vector3(0, 0, -8))
	)

	spawner.queue_free()
	_done()


## The same spawns make the same choices, however many unrelated objects came first.
##
## [b]The bug this pins:[/b] NPCs were seeded from `get_instance_id()`, the engine's object id,
## and one extra object created at startup moved every id, so a game's timing check flipped
## on a commit that touched nothing it measured, and a replay could not agree with its
## recording. Each run here creates a different number of throwaway objects before spawning;
## with the object id as the seed no two runs agree.
func _test_stable_seeds() -> void:
	_section("stable seeds")

	var quiet := _seeded_run(0, 0)
	var noisy := _seeded_run(37, 0)
	var noisier := _seeded_run(211, 0)

	_check(quiet.size() == 5 and noisy.size() == 5, "every scripted spawn landed",
		"%d and %d" % [quiet.size(), noisy.size()])
	_check(quiet == noisy and noisy == noisier,
		"the same spawns get the same seeds and first choices, whatever was created first",
		"%s vs %s" % [quiet, noisy])

	var seeds := {}
	var above_one := true

	for row: Array in quiet:
		seeds[row[0]] = true
		above_one = above_one and int(row[0]) > 1

	_check(seeds.size() == quiet.size(), "and no two NPCs share one",
		"or a horde turns, waits and misses in step")
	_check(above_one, "and every seed is above 1",
		"dot-npc-ai reads 0 and 1 as \"still the preset's seed\"")
	_check(_seeded_run(0, 99) != quiet, "a different seed_base is a different session")

	# The game's own number, its entity id in practice, wins over the spawn count, and
	# zero from it falls back rather than giving every NPC the seed of "0". The stand-in
	# here is where the NPC was placed, which the source can read because it is asked after
	# the node is in the world.
	var given := _seeded_run(0, 0, func(npc: DotNpcInstance) -> int:
		return 4096 + roundi(npc.position().x))
	var given_again := _seeded_run(53, 0, func(npc: DotNpcInstance) -> int:
		return 4096 + roundi(npc.position().x))
	_check(given == given_again and given != quiet,
		"a seed_source number is used, and is as stable as what the game gave")
	_check(_seeded_run(0, 0, func(_npc: DotNpcInstance) -> int: return 0) == quiet,
		"and a seed_source answering 0 falls back to the spawn count")

	var loose := _loose_npc(DotNpcDef.make(&"loose", BODY))
	_check(loose.seed == 0, "an NPC built by hand is unseeded, and says so with 0")
	loose.node.free()
	_done()


## One scripted run: [param noise] throwaway objects, then five spawns. Returns
## `[seed, first_choices]` per NPC in spawn order.
func _seeded_run(noise: int, base: int, source: Callable = Callable()) -> Array:
	var junk: Array[Object] = []

	for i in noise:
		junk.append(Node.new() if i % 2 == 0 else Object.new())

	var cat := _catalogue()
	var chooser := DotNpcDef.make(&"chooser", BODY)
	chooser.brain_script_path = CHOOSER
	chooser.require_line_of_sight = false
	cat.add(chooser)

	var spawner := DotNpcSpawner.new()
	spawner.catalogue = cat
	spawner.limits = _limits()
	spawner.authoritative = true
	spawner.seed_base = base
	spawner.seed_source = source
	_world.add_child(spawner)

	var out: Array = []

	for i in 5:
		var npc := spawner.spawn(&"chooser", Vector3(float(i) * 2.0, 0.0, 0.0))

		if npc != null and npc.brain != null:
			out.append([npc.seed, (npc.brain.get(&"first_choices") as Array).duplicate()])

	_world.remove_child(spawner)
	spawner.free()

	for thing in junk:
		thing.free()

	return out


## A brain and its NPC point at each other. See [method DotNpcBrain.unbind].
func _test_brains_are_released() -> void:
	_section("a brain and its NPC let go of each other")

	var spawner := _spawner()
	var removed := spawner.spawn(&"walker", Vector3.ZERO)
	var kept := spawner.spawn(&"walker", Vector3.ZERO)

	var removed_brain: WeakRef = weakref(removed.brain)
	spawner.remove(removed.instance_id)
	removed = null

	_check(removed_brain.get_ref() == null, "a removed NPC's brain is freed")

	# [b]The path that leaked: nobody removes anything.[/b] A world is torn down by freeing
	# its nodes, so the spawner's own table goes and every NPC in it is left holding its
	# brain while the brain holds it. Freed rather than queued, so PREDELETE runs now.
	var kept_brain: WeakRef = weakref(kept.brain)
	var kept_npc: WeakRef = weakref(kept)
	kept = null
	_world.remove_child(spawner)
	spawner.free()

	_check(kept_brain.get_ref() == null, "and a freed spawner's brains go with it",
		"the spawner never removed them, and the brain and the NPC point at each other")
	_check(kept_npc.get_ref() == null, "and so do the NPCs")
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
	DotNpcGore.reset()
	DotNpcGore.max_wounds = 0
	_check(not DotNpcGore.wounds_enabled() and DotNpcGibs.add_wound(null, Vector3.ZERO) == null and DotNpcGibs.add_pool(null, Vector3.ZERO) == null,
		"a wound cap of 0 draws no marks or pools")
	DotNpcGore.reset()
	off.queue_free()
	soft.queue_free()
	capped.queue_free()
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
