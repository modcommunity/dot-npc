extends Node
## State, counters and builders shared by the dot-npc suite layers.

const BODY := "res://fixtures/npc_body.tscn"
const BODY_2D := "res://fixtures/npc_body_2d.tscn"
const BRAIN := "res://fixtures/walker_brain.gd"
const CHOOSER := "res://fixtures/chooser_brain.gd"


var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var _world: Node3D = null


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

	# A 2D NPC in the same catalogue as the 3D ones: a [DotNpcDef] says nothing about dimension, so the
	# spawner has to pick the right entry point rather than infer one.
	var swarmer := DotNpcDef.make(&"swarmer", BODY_2D)
	swarmer.brain_script_path = BRAIN
	swarmer.category = &"swarm"
	swarmer.max_health = 40.0
	swarmer.sight_range = 300.0
	# Off, and it has to be for a 2D NPC: there is no 3D physics world to cast through, and saying so in the
	# definition makes the "clear" answer a decision rather than a fallback nobody noticed.
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


## An NPC at the origin, facing -Z, with no spawner behind it.
## Built by hand so the perception tests are about perception, not whether a scene loaded.
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
