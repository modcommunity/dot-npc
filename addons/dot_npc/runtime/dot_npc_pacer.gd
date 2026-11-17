class_name DotNpcPacer
extends RefCounted

## The spawner's think pacing in script: which NPCs think this tick and with how much time.
## The twin of dot-sim's native `DotSimThinkPacer` (same calls, same answers to the bit); [DotNpcPacing] picks
## one, or runs both and compares them.
##
## A paced brain ([method DotNpcBrain.paces]) thinks once every `every` ticks and is handed the seconds it owes
## (the ticks' deltas summed in order). Rows keep the spawner's NPC order. A tick: [method advance] lists the due
## rows without changing any (an unpaced row always is, owing -1; a paced one when `since + 1 >= every`), the
## spawner thinks them, and [method settle] commits it (a thought row restarts with its new `every`, every
## other paced row counts). A change made by a brain mid-tick goes through [method commit_to] and
## [method due_after]; a row added mid-tick sits the tick out; one removed stays a gap until settle.

const PACED := 1
const FRESH := 2
const DONE := 4
const GONE := 8

var _id := PackedInt64Array()
var _since := PackedInt64Array()
var _owed := PackedFloat64Array()
var _every := PackedInt64Array()
var _flags := PackedByteArray()

## Id -> row index.
var _at: Dictionary = {}
var _gone := 0
var _delta := 0.0
var _looping := false

var _ids := PackedInt64Array()
var _owe := PackedFloat64Array()


func size() -> int:
	return _id.size() - _gone


func clear() -> void:
	_id.clear()
	_since.clear()
	_owed.clear()
	_every.clear()
	_flags.clear()
	_at.clear()
	_gone = 0
	_looping = false


func looping() -> bool:
	return _looping


func _live(id: int) -> int:
	var i: int = _at.get(id, -1)
	return i if i >= 0 and _flags[i] & GONE == 0 else -1


func _reindex(from: int) -> void:
	for j in range(from, _id.size()):
		_at[_id[j]] = j


func _drop(i: int) -> void:
	_id.remove_at(i)
	_since.remove_at(i)
	_owed.remove_at(i)
	_every.remove_at(i)
	_flags.remove_at(i)


func _counters(i: int) -> PackedFloat64Array:
	return PackedFloat64Array([float(_since[i]), _owed[i], float(_every[i])])


## Appends an NPC, unpaced. False when it already has a row.
func add(id: int) -> bool:
	var i: int = _at.get(id, -1)

	if i >= 0:
		if _flags[i] & GONE == 0:
			return false

		_drop(i)
		_gone -= 1
		_reindex(i)

	_at[id] = _id.size()
	_id.append(id)
	_since.append(0)
	_owed.append(0.0)
	_every.append(1)
	_flags.append(FRESH if _looping else 0)
	return true


## Drops an NPC's row; its counters [since, owed, every], or empty when it had none.
func remove(id: int) -> PackedFloat64Array:
	var i := _live(id)

	if i < 0:
		return PackedFloat64Array()

	var c := _counters(i)

	if _looping:
		_flags[i] |= GONE
		_gone += 1
	else:
		_at.erase(id)
		_drop(i)
		_reindex(i)

	return c


## Paces an NPC from the brain's counters, or stops; the counters the row held (empty when it has no row).
func set_paced(id: int, on: bool, since: int, owed: float, every: int) -> PackedFloat64Array:
	var i := _live(id)

	if i < 0:
		return PackedFloat64Array()

	var old := _counters(i)

	if on:
		_flags[i] |= PACED
		_since[i] = since
		_owed[i] = owed
		_every[i] = every
	else:
		_flags[i] &= ~PACED

	return old


## A brain's `every`, set outside its think. False when it has no row.
func set_every(id: int, every: int) -> bool:
	var i := _live(id)

	if i < 0:
		return false

	_every[i] = every
	return true


# -1 unpaced, -2 not due, else the seconds owed.
func _due(i: int) -> float:
	var f := _flags[i]

	if f & (FRESH | DONE | GONE) != 0:
		return -2.0

	if f & PACED == 0:
		return -1.0

	if _since[i] + 1 >= _every[i]:
		return _owed[i] + _delta

	return -2.0


## Starts a tick: the due NPCs in order. [method owed] then gives the seconds each owes (-1: unpaced).
func advance(delta: float) -> PackedInt64Array:
	if _looping:
		settle(PackedInt64Array(), PackedInt64Array())

	_delta = delta
	_looping = true
	_collect(0)
	return _ids


## The seconds owed by the NPCs of the last [method advance] or [method due_after].
func owed() -> PackedFloat64Array:
	return _owe


func _collect(start: int) -> void:
	_ids = PackedInt64Array()
	_owe = PackedFloat64Array()

	for i in range(start, _id.size()):
		var o := _due(i)

		if o != -2.0:
			_ids.append(_id[i])
			_owe.append(o)


func _commit(i: int, thought: Dictionary) -> void:
	var f := _flags[i]

	if f & (FRESH | DONE | GONE) != 0:
		return

	_flags[i] = f | DONE

	if f & PACED == 0:
		return

	var every: Variant = thought.get(_id[i])

	if every != null:
		_since[i] = 0
		_owed[i] = 0.0
		_every[i] = every
	else:
		_since[i] += 1
		_owed[i] += _delta


static func _thought_map(thought: PackedInt64Array, every: PackedInt64Array) -> Dictionary:
	var map := {}

	for k in mini(thought.size(), every.size()):
		map[thought[k]] = every[k]

	return map


## Commits the rows before `id` (through it when `through`) with the NPCs thought since the last commit and
## their new `every`. False outside a tick.
func commit_to(id: int, through: bool, thought: PackedInt64Array, every: PackedInt64Array) -> bool:
	if not _looping:
		return false

	var i: int = _at.get(id, -1)
	var end := _id.size() if i < 0 else i + int(through)
	var map := _thought_map(thought, every)

	for j in end:
		_commit(j, map)

	return true


## The NPCs after `id` still due this tick (all rows when `id` has none); [method owed] as after advance.
func due_after(id: int) -> PackedInt64Array:
	if not _looping:
		_ids = PackedInt64Array()
		_owe = PackedFloat64Array()
		return _ids

	_collect(int(_at.get(id, -1)) + 1)
	return _ids


## Ends the tick with the NPCs thought since the last commit and their new `every`. False outside a tick.
func settle(thought: PackedInt64Array, every: PackedInt64Array) -> bool:
	if not _looping:
		return false

	var map := _thought_map(thought, every)

	for i in _id.size():
		_commit(i, map)
		_flags[i] &= ~(FRESH | DONE)

	if _gone > 0:
		var i := _id.size() - 1

		while i >= 0:
			if _flags[i] & GONE != 0:
				_at.erase(_id[i])
				_drop(i)

			i -= 1

		_gone = 0
		_reindex(0)

	_looping = false
	return true


## An NPC's counters [since, owed, every, paced], or empty when it has no row.
func row(id: int) -> PackedFloat64Array:
	var i := _live(id)

	if i < 0:
		return PackedFloat64Array()

	return PackedFloat64Array([float(_since[i]), _owed[i], float(_every[i]), float(_flags[i] & PACED)])
