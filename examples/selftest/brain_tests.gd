extends "res://examples/selftest/spawner_tests.gd"
## Brains, seeds, damage, reclaim and leak sections.

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
## Pins seeding from `get_instance_id()`: one extra startup object moved every id and flipped timing checks;
## each run here creates a different number of throwaway objects before spawning.
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

	# The game's own number (its entity id) wins over the spawn count, and zero falls back rather than
	# giving every NPC the seed of "0". The stand-in here is where the NPC was placed.
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
