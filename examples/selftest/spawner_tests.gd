extends "res://examples/selftest/senses_tests.gd"
## Spawning, authority, budgets and pathing sections.

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

	# No hard caps: burst_cap 0 is unlimited, a positive one still caps.
	var open := _limits()
	open.world_budget = 0
	open.per_kind_cap = 0
	open.burst_cap = 0
	var wide := _spawner(open)
	_check(wide.spawn_group(&"walker", Vector3.ZERO, 30, 6.0).size() == 30, "burst_cap 0 spawns the whole group")
	open.burst_cap = 3
	_check(wide.spawn_group(&"walker", Vector3(50, 0, 0), 30, 6.0).size() == 3, "and burst_cap 3 still caps it")
	open.burst_cap = -1
	_check(not open.validate().ok, "a negative burst_cap is refused")
	wide.queue_free()

	# sense_candidate_cap 0 ranks every candidate in reach.
	var spots := PackedVector3Array()
	for i in 40:
		spots.append(Vector3(float(i) + 1.0, 0, 0))
	var loud := PackedFloat64Array()
	loud.resize(40)
	var sides := PackedInt32Array()
	sides.resize(40)
	sides.fill(1)
	var ranked: Array = DotNpcSenses.rank_many(0, 1, PackedVector3Array([Vector3.ZERO]), PackedFloat64Array([100.0]),
		PackedFloat64Array([0.0]), PackedInt32Array([0]), spots, loud, sides, 0)
	_check((ranked[0] as PackedInt32Array).size() == 40, "candidate cap 0 ranks all 40", str((ranked[0] as PackedInt32Array).size()))
	ranked = DotNpcSenses.rank_many(0, 1, PackedVector3Array([Vector3.ZERO]), PackedFloat64Array([100.0]),
		PackedFloat64Array([0.0]), PackedInt32Array([0]), spots, loud, sides, 4)
	_check((ranked[0] as PackedInt32Array).size() == 4 and (ranked[0] as PackedInt32Array)[0] == 0,
		"and cap 4 keeps the nearest four")
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


const PACE_TICKS := 1500

## Think pacing: brains that think every few ticks and stagger, possess, free, remove and spawn each other mid-tick
## give the same log of thoughts (who, when, with how many seconds) with pacing off, counted by the script pacer,
## counted natively (checked against the script call for call), and toggled on and off every 97 ticks.
func _test_pacing() -> void:
	_section("think pacing")

	var off := _pace_run(false, false, 0)
	var thoughts := 0
	var kinds := {}
	for e in off:
		kinds[e[0]] = true
		if e[0] == "think":
			thoughts += 1
	_check(thoughts > 1000 and kinds.size() >= 6, "the run thinks and does every kind of event",
		"%d thoughts, %s" % [thoughts, kinds.keys()])

	var script := _pace_run(true, false, 0)
	_check(script == off, "script pacing: the same log as each brain counting", _pace_diff(script, off))

	var toggled := _pace_run(true, false, 97)
	_check(toggled == off, "pacing toggled every 97 ticks: the same log", _pace_diff(toggled, off))

	# Five checks either way (CHECKS): with GameSpice Sim the native pacer, without it the fallback when native is asked for.
	if ClassDB.class_exists(&"DotSimThinkPacer"):
		var checks := [0, 0]
		var native := _pace_run(true, true, 0, checks)
		var native_toggled := _pace_run(true, true, 97)
		_check(native == off and native_toggled == off, "native pacing (and toggled every 97 ticks): the same log",
			"%s / %s" % [_pace_diff(native, off), _pace_diff(native_toggled, off)])
		_check(checks[0] > 1000 and checks[1] == 0, "and verify matched the script pacer call for call",
			"%d checked, %d differ" % checks)
	else:
		var flags := [false]
		var fallback := _pace_run(true, true, 0, [], flags)
		_check(fallback == off, "native asked for without dot-sim: script pacing, the same log", _pace_diff(fallback, off))
		_check(not flags[0], "and the spawner says it is not native")

	_done()


func _pace_diff(a: Array, b: Array) -> String:
	for i in mini(a.size(), b.size()):
		if a[i] != b[i]:
			return "entry %d: %s vs %s" % [i, a[i], b[i]]
	return "%d vs %d entries" % [a.size(), b.size()]


func _pace_run(pacing: bool, native: bool, toggle_every: int, checks: Array = [], native_seen: Array = []) -> Array:
	var limits := _limits()
	limits.world_budget = 0
	limits.per_kind_cap = 0
	limits.spawn_interval = 0.0
	var spawner := _spawner(limits)
	var def := DotNpcDef.make(&"pacer", BODY)
	def.brain_script_path = "res://fixtures/paced_brain.gd"
	def.max_health = 100.0
	def.require_line_of_sight = false
	spawner.catalogue.add(def)
	spawner.pacing = pacing
	spawner.pacing_native = native
	spawner.pacing_verify = native and checks.size() == 2
	spawner.set_meta(&"pace_log", [])

	for i in 30:
		spawner.spawn(&"pacer", Vector3(i * 1.5 - 22.0, 0, (i % 5) * 3.0 - 6.0))

	for t in PACE_TICKS:
		if toggle_every > 0 and t % toggle_every == 0 and t > 0:
			spawner.pacing = not spawner.pacing
		spawner.tick(0.016)

	if native_seen.size() == 1:
		native_seen[0] = spawner.pacing_is_native()

	if checks.size() == 2:
		checks[0] = spawner.pacing_checked
		checks[1] = spawner.pacing_mismatches

	var out: Array = spawner.get_meta(&"pace_log", [])
	spawner.queue_free()
	return out
