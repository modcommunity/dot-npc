extends "res://addons/dot_npc/runtime/dot_npc_brain.gd"

## A brain for the self-test that thinks every few ticks the way a far-off zombie does, counting its own ticks
## (or letting the spawner count them when pacing is on), and on some thoughts staggers, possesses, frees, kills or
## spawns another NPC mid-tick. Every thought and driven tick goes to the spawner's `pace_log` meta, so a run with
## pacing off, script pacing and native pacing can be compared entry for entry.

var _since_thought: int = 0
var _owed_delta: float = 0.0
var _every: int = 1
var thoughts: int = 0


func paces() -> bool:
	return true


func _npc_think(delta: float) -> void:
	_since_thought += 1
	_owed_delta += delta

	if _since_thought < _every:
		return

	delta = _owed_delta
	_owed_delta = 0.0
	_since_thought = 0
	_think_now(delta)
	_every = _think_every()


func think_paced(owed: float) -> int:
	age += owed
	_think_now(owed)
	_every = _think_every()
	return _every


func _pace_take() -> Array:
	return [_since_thought, _owed_delta, _every]


func _pace_give(since: int, owed: float, every: int) -> void:
	_since_thought = since
	_owed_delta = owed
	_every = every


func _npc_driven(delta: float) -> void:
	_log(["driven", npc.seed, director.now(), delta])


## Called by another brain mid-tick: thinks every tick for a while.
func stagger() -> void:
	_every = 1
	pace_every(1)


func _think_every() -> int:
	return 1 + absi(hash([npc.seed, thoughts])) % 6


func _think_now(delta: float) -> void:
	thoughts += 1
	_log(["think", npc.seed, director.now(), delta])
	var roll := absi(hash([npc.seed, thoughts, 7])) % 40
	var others: Array = director.call(&"all_npcs")

	if others.is_empty():
		return

	var other: DotNpcInstance = others[absi(hash([npc.seed, thoughts, 3])) % others.size()]

	if other == npc or other.brain == null:
		return

	match roll:
		0, 1, 2:
			if other.brain.has_method(&"stagger"):
				other.brain.stagger()
				_log(["stagger", npc.seed, other.seed])
		3:
			if other.brain.drive == null:
				var drive := DotNpcDrive.new()
				drive.grab(&"p")
				other.brain.drive = drive
				_log(["drive", npc.seed, other.seed])
		4, 5:
			if other.brain.drive != null:
				other.brain.drive = null
				_log(["free", npc.seed, other.seed])
		6:
			if director.call(&"world_count") > 8:
				_log(["remove", npc.seed, other.seed])
				director.call(&"remove", other.instance_id)
		7:
			var made: Variant = director.call(&"spawn", npc.def.id, npc.position() + Vector3(0.5, 0, 0.5))
			if made != null:
				_log(["spawn", npc.seed, (made as DotNpcInstance).seed])
		8:
			if drive == null:
				# Its own pacing changes during its own turn.
				var mine := DotNpcDrive.new()
				mine.grab(&"q")
				drive = mine
				_log(["self-drive", npc.seed])


func _log(entry: Array) -> void:
	var into: Array = director.get_meta(&"pace_log", [])
	into.append(entry)
	director.set_meta(&"pace_log", into)
