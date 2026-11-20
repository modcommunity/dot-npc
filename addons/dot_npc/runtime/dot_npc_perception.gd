class_name DotNpcPerception
extends RefCounted
## The spawner's perception pass (ranking candidates, committing targets) and the reclaim sweep.

var s: DotNpcSpawner
var packed := DotNpcSenses.Packed.new()

func _init(spawner: DotNpcSpawner) -> void:
	s = spawner

func perceive() -> void:
	if s.senses == null or s.limits == null:
		return

	var period := maxi(s.limits.sense_period_ticks, 1)
	var quiet_period := period * maxi(s.limits.sense_quiet_mult, 1)
	var slot := 0
	var due: Array[DotNpcInstance] = []

	for id in s._npcs:
		var npc: DotNpcInstance = s._npcs[id]

		if not npc.is_alive():
			continue

		# Staggered by dictionary position, never instance id: ids of one wave are consecutive
		# and would put the whole wave on the same tick.
		slot += 1

		var every := quiet_period if npc.sense_quiet and not npc.has_target() else period

		if (slot + s._ticks) % every != 0 or npc.def == null:
			continue

		due.append(npc)

	if due.is_empty():
		return

	packed.fill(s._candidates)

	var nat: Object = s.senses.native()

	if nat != null:
		_perceive_native(nat, due)
		return

	var n := due.size()
	var here := PackedVector3Array()
	var sight := PackedFloat64Array()
	var hearing := PackedFloat64Array()
	var own := PackedInt32Array()
	here.resize(n)
	sight.resize(n)
	hearing.resize(n)
	own.resize(n)

	for i in n:
		var npc := due[i]
		here[i] = npc.position()
		sight[i] = DotNpcSenses.reach_of(npc)
		hearing[i] = npc.def.hearing_range
		own[i] = packed.faction_of(npc.def.faction)

	var cap := s.limits.sense_candidate_cap
	var positions := packed.positions
	var loudness := packed.loudness
	var factions := packed.factions
	var chunks := ceili(float(n) / DotNpcSpawner.SENSE_CHUNK)
	var task := func(c: int) -> Array:
		return DotNpcSenses.rank_many(c * DotNpcSpawner.SENSE_CHUNK, mini(n, (c + 1) * DotNpcSpawner.SENSE_CHUNK),
			here, sight, hearing, own, positions, loudness, factions, cap)
	var ranked := DotParallel.run(task, chunks, &"npc.senses", s.sense_workers)

	for c in chunks:
		var orders: Array = ranked[c]

		for k in orders.size():
			var npc := due[c * DotNpcSpawner.SENSE_CHUNK + k]
			var before := npc.target_id
			npc.sense_quiet = orders[k].is_empty()
			var after := s.senses.decide(npc, s._candidates, orders[k],
				packed.index_of(npc.target_id), s._now)

			if after != before:
				s.target_changed.emit(npc, after)

## Answer codes of `DotSimSenses.perceive`.
const _KEEP := -1
const _CLEAR := -2
const _SEEN := 1
const _SINCE := 2
const _QUIET := 4

## The pass in GameSpice Sim: the same answers as the script loop above, applied in the same order.
func _perceive_native(nat: Object, due: Array[DotNpcInstance]) -> void:
	var n := due.size()
	var senses := s.senses
	var now := s._now
	senses.now = now
	var npc_f := PackedFloat64Array()
	var npc_i := PackedInt32Array()
	var nodes: Array = []
	npc_f.resize(n * 13)
	npc_i.resize(n * 4)
	nodes.resize(n)

	for k in n:
		var npc := due[k]
		var def := npc.def
		var at := npc.position()
		var facing := npc.facing()
		var f := k * 13
		npc_f[f] = at.x
		npc_f[f + 1] = at.y
		npc_f[f + 2] = at.z
		npc_f[f + 3] = facing.x
		npc_f[f + 4] = facing.y
		npc_f[f + 5] = facing.z
		npc_f[f + 6] = def.eye_height
		npc_f[f + 7] = DotNpcSenses.reach_of(npc)
		npc_f[f + 8] = def.hearing_range
		npc_f[f + 9] = def.sight_half_angle_deg
		npc_f[f + 10] = def.sight_half_angle()
		npc_f[f + 11] = npc.blind_until
		npc_f[f + 12] = npc.target_seen_at
		var j := k * 4
		npc_i[j] = packed.faction_of(def.faction)
		npc_i[j + 1] = packed.index_of(npc.target_id)
		npc_i[j + 2] = 1 if npc.has_target() else 0
		npc_i[j + 3] = 1 if def.require_line_of_sight else 0
		nodes[k] = npc.node

	var out: PackedInt32Array = nat.perceive(now, s.limits.sense_candidate_cap, npc_f, npc_i, nodes,
		packed.positions, packed.loudness, packed.factions, packed.firsts, senses.packed_blockers())
	senses.native_decided += n

	if senses.native_verify:
		_verify_native(due, out)
		return

	for k in n:
		var npc := due[k]
		var before := npc.target_id
		_apply(npc, out[k * 2], out[k * 2 + 1], now)

		if npc.target_id != before:
			s.target_changed.emit(npc, npc.target_id)

	senses.sight_checks += out[n * 2]
	senses.los_casts += out[n * 2 + 1]

## Writes one native answer onto [param npc], as [method DotNpcSenses.decide] would have.
func _apply(npc: DotNpcInstance, target: int, flags: int, now: float) -> void:
	npc.sense_quiet = (flags & _QUIET) != 0

	if target == _CLEAR:
		npc.target_id = &""
	elif target >= 0:
		npc.target_id = (s._candidates[target] as DotNpcSenses.Candidate).id

	if flags & _SEEN:
		npc.target_seen_at = now
		npc.engaged_at = now

	if flags & _SINCE:
		npc.target_since = now

## The script pass over [param due] with every NPC's state compared against the native answer
## [param out] first applied to a copy; the script's answer is what stays.
func _verify_native(due: Array[DotNpcInstance], out: PackedInt32Array) -> void:
	var senses := s.senses
	var now := s._now
	var n := due.size()
	var checks := senses.sight_checks
	var casts := senses.los_casts
	var here := PackedVector3Array()
	var sight := PackedFloat64Array()
	var hearing := PackedFloat64Array()
	var own := PackedInt32Array()
	here.resize(n)
	sight.resize(n)
	hearing.resize(n)
	own.resize(n)

	for i in n:
		var npc := due[i]
		here[i] = npc.position()
		sight[i] = DotNpcSenses.reach_of(npc)
		hearing[i] = npc.def.hearing_range
		own[i] = packed.faction_of(npc.def.faction)

	var orders := DotNpcSenses.rank_many(0, n, here, sight, hearing, own, packed.positions,
		packed.loudness, packed.factions, s.limits.sense_candidate_cap)

	for k in n:
		var npc := due[k]
		var before := npc.target_id
		var want := DotNpcInstance.new()
		want.target_id = npc.target_id
		want.target_seen_at = npc.target_seen_at
		want.engaged_at = npc.engaged_at
		want.target_since = npc.target_since
		_apply(want, out[k * 2], out[k * 2 + 1], now)
		npc.sense_quiet = orders[k].is_empty()
		var after := senses.decide(npc, s._candidates, orders[k], packed.index_of(npc.target_id), now)

		if want.target_id != npc.target_id or want.target_seen_at != npc.target_seen_at \
				or want.engaged_at != npc.engaged_at or want.target_since != npc.target_since \
				or want.sense_quiet != npc.sense_quiet:
			senses.native_mismatches += 1

		if after != before:
			s.target_changed.emit(npc, after)

	if senses.sight_checks - checks != out[n * 2] or senses.los_casts - casts != out[n * 2 + 1]:
		senses.native_mismatches += 1

func reclaim() -> void:
	if s.limits == null or s.limits.reclaim_distance <= 0.0:
		return

	if s._candidates.is_empty():
		# Nobody to be far from. Reclaiming here would empty a server the moment its
		# last player disconnected, and a dedicated server between rounds is exactly
		# that — with the wave it is about to hand the next player already spawned.
		return

	var ids: Array = s._npcs.keys()
	var limit_sq := s.limits.reclaim_distance * s.limits.reclaim_distance

	for id in ids:
		var found: Variant = s._npcs.get(id)

		if not (found is DotNpcInstance):
			continue

		var npc: DotNpcInstance = found

		if not npc.is_alive() or npc.has_target():
			continue

		if s._now - npc.engaged_at < s.limits.reclaim_grace:
			continue

		var nearest_sq := INF
		var position := npc.position()

		for entry in s._candidates:
			var cand := entry as DotNpcSenses.Candidate

			if cand != null:
				nearest_sq = minf(nearest_sq, position.distance_squared_to(cand.position))

		if nearest_sq > limit_sq:
			s.reclaim_count += 1
			s.remove(npc.instance_id, DotNpcSpawner.REASON_RECLAIMED)
