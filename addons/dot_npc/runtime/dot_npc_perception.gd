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
