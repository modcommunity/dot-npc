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
