extends "res://examples/selftest/nav_path_tests.gd"
## Senses sections.


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
## dot-npc-ai measures reaction time against it; `engaged_at` refreshes every pass a target is seen, so a
## timer against that never elapses and every branch behind it never runs, with no error.
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


## Held-first pruning commits exactly as the full nearest-first pass, with fewer tests.
func _test_senses_pruning() -> void:
	_section("senses: held-first pruning")

	var full := DotNpcSenses.new()
	full.prune_by_held = false
	var pruned := DotNpcSenses.new()
	var def := DotNpcDef.make(&"pruner", BODY)
	def.require_line_of_sight = false
	def.sight_half_angle_deg = 60.0
	def.sight_range = 30.0
	def.hearing_range = 12.0
	var npc := _loose_npc(def)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var same := 0
	var switched := 0
	var kept := 0
	var trials := 600

	for t in trials:
		(npc.node as Node3D).rotation.y = rng.randf_range(-PI, PI)
		var list: Array = []

		for i in rng.randi_range(0, 14):
			var at := Vector3(rng.randf_range(-35, 35), 0, rng.randf_range(-35, 35))
			var faction := def.faction if rng.randf() < 0.15 else &"player"
			list.append(_candidate(StringName("c%d" % i), at, faction, 20.0 if rng.randf() < 0.3 else 0.0))

		var pick := rng.randi_range(-2, list.size() - 1)
		var held: StringName = &"" if pick == -2 else (&"gone" if pick == -1 else (list[pick] as DotNpcSenses.Candidate).id)
		var start := [held, rng.randf_range(0.0, 5.0), 1.0, 0.5]
		var results: Array = []

		for senses in [full, pruned]:
			npc.target_id = start[0]
			npc.target_seen_at = start[1]
			npc.engaged_at = start[2]
			npc.target_since = start[3]
			var got: StringName = senses.update_target(npc, list, 6.0, 8)
			results.append([got, npc.target_id, npc.target_seen_at, npc.engaged_at, npc.target_since])

		if results[0] == results[1]:
			same += 1

		if held != &"" and results[1][1] == held:
			kept += 1
		elif held != &"" and results[1][1] != &"":
			switched += 1

	_check(same == trials, "every trial commits as the full pass does (%d of %d)" % [same, trials])
	_check(kept > 50 and switched > 20, "and the trials cover both keeping and switching (%d kept, %d switched)" % [kept, switched])
	_check(pruned.sight_checks < full.sight_checks,
		"with fewer perception tests (%d against %d)" % [pruned.sight_checks, full.sight_checks])
	npc.node.queue_free()
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


## An NPC that found nobody senses less often, and notices a newcomer within the longer period.
func _test_senses_quiet() -> void:
	_section("senses: the quiet period")

	var limits := _limits()
	limits.sense_period_ticks = 1
	limits.sense_quiet_mult = 4
	limits.per_kind_cap = 100
	limits.burst_cap = 100
	var spawner := _spawner(limits)
	var npcs: Array = []

	for i in 8:
		npcs.append(spawner.spawn(&"critter", Vector3(float(i) * 0.3, 0, 0)))

	spawner.set_candidates([])

	for _t in 4:
		spawner.tick(1.0 / 60.0)

	var quiet := 0

	for npc in npcs:
		quiet += 1 if npc.sense_quiet else 0

	_check(quiet == npcs.size(), "with nobody about every NPC goes quiet (%d of %d)" % [quiet, npcs.size()])

	spawner.set_candidates([_candidate(&"p", Vector3(1.0, 0, -3.0))])
	var first := -1
	var last := -1

	for t in 8:
		spawner.tick(1.0 / 60.0)
		var seen := 0

		for npc in npcs:
			seen += 1 if npc.target_id == &"p" else 0

		if seen > 0 and first < 0:
			first = t

		if seen == npcs.size() and last < 0:
			last = t

	_check(first >= 0 and last >= 0 and last < 4, "a newcomer is noticed by all within the quiet period (first %d, last %d)" % [first, last])
	_check(first < last, "and the quiet ones are staggered, not all on one tick (%d, %d)" % [first, last])

	spawner.set_candidates([])
	limits.sense_quiet_mult = 1

	for npc in npcs:
		npc.target_id = &""
		npc.sense_quiet = true

	spawner.set_candidates([_candidate(&"p", Vector3(1.0, 0, -3.0))])
	spawner.tick(1.0 / 60.0)
	var now := 0

	for npc in npcs:
		now += 1 if npc.target_id == &"p" else 0

	_check(now == npcs.size(), "with the multiplier at 1 every NPC senses each tick again (%d)" % now)
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
