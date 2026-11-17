class_name DotNpcPacing
extends RefCounted
## The spawner's think pacing: counts the ticks of every brain that [method DotNpcBrain.paces] in one batch,
## natively when dot-sim's `DotSimThinkPacer` is loaded, so only the brains due this tick are called.
## Off ([member DotNpcSpawner.pacing] false) the spawner calls every brain every tick, as before.
##
## Exactly what the brains' own counting gives: the same brains think on the same ticks with the same seconds,
## in the spawner's order, through spawns, removals, staggers and possessions mid-tick. A brain that changes
## another's pacing while it thinks has the rows before it committed as the script would hold them, and the
## rest of the tick's due list read again ([method DotNpcPacer.commit_to], [method DotNpcPacer.due_after]).

const NATIVE := &"DotSimThinkPacer"

var _spawner: DotNpcSpawner

## The pacer in use (native or [DotNpcPacer]); null while pacing is off.
var _pacer: Object = null
## The script twin checked against the native pacer in verify mode.
var _twin: DotNpcPacer = null
var _on := false
var _native := false
var _verify := false
var _warned := false

## The NPC thinking now (0 between turns), the rows thought since the last commit, and their new `every`.
var _cur := 0
var _thought := PackedInt64Array()
var _everies := PackedInt64Array()
## This tick's due list from the read point on, the seconds each owes, and where the loop is in it.
var _due := PackedInt64Array()
var _owe := PackedFloat64Array()
var _q := 0
## The thinking NPC's own pacing changed during its turn: applied when the turn ends.
var _cur_changed := false


func _init(spawner: DotNpcSpawner) -> void:
	_spawner = spawner


## Whether pacing is on (after the last [method sync]).
func active() -> bool:
	return _on


## Whether the native pacer is the one in use.
func native() -> bool:
	return _on and _native


## Adopts the spawner's settings; between ticks only. Turning off hands every paced brain its counters back.
func sync() -> void:
	var s := _spawner
	var has_native := ClassDB.class_exists(NATIVE)
	var on := s.pacing
	var native_wanted := on and s.pacing_native
	var native := native_wanted and has_native
	var verify := native and s.pacing_verify

	if native_wanted and not has_native and not _warned:
		_warned = true
		DotLog.warn(DotNpcSpawner.CHANNEL, "native think pacing asked for but dot-sim is not loaded; script pacing", {})

	if on == _on and native == _native and verify == _verify:
		return

	if _on:
		_give_back()

	_on = on
	_native = native
	_verify = verify
	_pacer = null
	_twin = null

	if not on:
		return

	_pacer = ClassDB.instantiate(NATIVE) if native else DotNpcPacer.new()
	_twin = DotNpcPacer.new() if verify else null

	for id in s._npcs:
		_c(&"add", [id])
		var npc: DotNpcInstance = s._npcs[id]

		if _wants(npc):
			_toggle(npc, true)


func _give_back() -> void:
	var s := _spawner

	for id in s._npcs:
		var npc: DotNpcInstance = s._npcs[id]
		var r: PackedFloat64Array = _c(&"row", [id])

		if r.size() == 4 and r[3] != 0.0 and npc.brain is DotNpcBrain:
			(npc.brain as DotNpcBrain)._pace_give(int(r[0]), r[1], int(r[2]))


# One call on the pacer, checked against the twin in verify mode (bit for bit).
func _c(method: StringName, args: Array) -> Variant:
	var got: Variant = _pacer.callv(method, args)

	if _twin != null:
		var want: Variant = _twin.callv(method, args)
		_spawner.pacing_checked += 1

		if var_to_bytes(got) != var_to_bytes(want):
			_spawner.pacing_mismatches += 1

			if _spawner.pacing_mismatches == 1:
				DotLog.error(DotNpcSpawner.CHANNEL, "native think pacing differs from the script", {
					"call": String(method), "args": str(args), "native": str(got), "script": str(want),
				})

	return got


static func _wants(npc: DotNpcInstance) -> bool:
	if npc == null or not (npc.brain is DotNpcBrain):
		return false

	var brain := npc.brain as DotNpcBrain
	return brain.paces() and brain.drive == null


func _toggle(npc: DotNpcInstance, on: bool) -> void:
	var brain := npc.brain as DotNpcBrain

	if on:
		var c: Array = brain._pace_take()
		_c(&"set_paced", [npc.instance_id, true, int(c[0]), float(c[1]), int(c[2])])
		return

	var old: PackedFloat64Array = _c(&"set_paced", [npc.instance_id, false, 0, 0.0, 1])

	if old.size() == 3 and brain != null:
		brain._pace_give(int(old[0]), old[1], int(old[2]))


## A spawned NPC, in the spawner's order (before its brain is attached).
func added(npc: DotNpcInstance) -> void:
	if _on:
		_c(&"add", [npc.instance_id])


## A removed NPC. Its brain is being let go, so its counters are not handed back.
func removed(npc: DotNpcInstance) -> void:
	if _on:
		_c(&"remove", [npc.instance_id])


## [param npc]'s pacing may have changed: a brain attached, or a drive taken or let go. [param retake] reads the
## counters from the brain again even when it stays paced (a new brain).
func changed(npc: DotNpcInstance, retake: bool = false) -> void:
	if not _on or npc == null:
		return

	var id := npc.instance_id
	var r: PackedFloat64Array = _c(&"row", [id])

	if r.is_empty():
		return

	var want := _wants(npc)

	if want == (r[3] != 0.0) and not (want and retake):
		return

	var looping: bool = _c(&"looping", [])

	if looping and id == _cur:
		_cur_changed = true
		return

	if looping:
		_commit_before()

	_toggle(npc, want)

	if looping:
		_reread()


## A brain set its `every` to [param n] outside its own think (a stagger).
func every(npc: DotNpcInstance, n: int) -> void:
	if not _on or npc == null or not _wants(npc):
		return

	var id := npc.instance_id

	# Its own think's result overwrites it.
	if id == _cur:
		return

	var looping: bool = _c(&"looping", [])

	if looping:
		_commit_before()

	_c(&"set_every", [id, n])

	if looping:
		_reread()


func _commit_before() -> void:
	_c(&"commit_to", [_cur, false, _thought, _everies])
	_thought = PackedInt64Array()
	_everies = PackedInt64Array()


func _reread() -> void:
	_due = _c(&"due_after", [_cur])
	_owe = _c(&"owed", [])
	_q = 0


## One tick's thinking for every NPC, in the spawner's order: a paced brain that is due gets
## [method DotNpcBrain.think_paced], an unpaced one [method DotNpcBrain.think] or its gather into [param split].
## Pacing off, every brain is called and counts for itself.
func think(delta: float, split: Array, gathered: Array) -> void:
	if not _on:
		# A copy, because a brain may kill its NPC — a suicide bomber is the obvious one —
		# and removing from the dictionary being iterated skips every other NPC.
		for id in _spawner._npcs.keys():
			_call(id, -1.0, delta, split, gathered)
		return

	_due = _c(&"advance", [delta])
	_owe = _c(&"owed", [])
	_q = 0
	_thought = PackedInt64Array()
	_everies = PackedInt64Array()

	while _q < _due.size():
		var id := _due[_q]
		var owed := _owe[_q]
		_q += 1
		_cur = id
		var npc := _call(id, owed, delta, split, gathered)

		if npc == null:
			_cur = 0
			continue

		if _cur_changed:
			_cur_changed = false
			_c(&"commit_to", [id, true, _thought, _everies])
			_thought = PackedInt64Array()
			_everies = PackedInt64Array()
			var r: PackedFloat64Array = _c(&"row", [id])

			if not r.is_empty() and _wants(npc) != (r[3] != 0.0):
				_toggle(npc, _wants(npc))

			_reread()

		_cur = 0

	_c(&"settle", [_thought, _everies])
	_thought = PackedInt64Array()
	_everies = PackedInt64Array()


# Thinks for NPC [param id] if it is alive with a brain, and returns it (null otherwise). [param owed] >= 0
# is a paced turn owing that many seconds; below 0, an unpaced one of [param delta].
func _call(id: int, owed: float, delta: float, split: Array, gathered: Array) -> DotNpcInstance:
	var found: Variant = _spawner._npcs.get(id)

	if not (found is DotNpcInstance):
		return null

	var npc: DotNpcInstance = found

	if not npc.is_alive() or npc.brain == null:
		return null

	var brain := npc.brain as DotNpcBrain

	if owed >= 0.0:
		_everies.append(brain.think_paced(owed))
		_thought.append(id)
	elif brain.splits_think():
		brain.age += delta
		split.append(brain)
		gathered.append(brain._npc_gather(delta))
	else:
		brain.think(delta)

	return npc
