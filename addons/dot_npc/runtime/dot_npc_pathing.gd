class_name DotNpcPathing
extends RefCounted
## The spawner's repath policy and the queue of repaths answered together on worker threads.

var _spawner: DotNpcSpawner
## def id -> DotNpcNavFilter, built on first use.
var _filters: Dictionary = {}
## [DotNpcPath, DotNpcNavGraph.PathQuery, goal] per queued repath, in the order asked.
var _queue: Array = []
var _pending: Dictionary = {}


func _init(spawner: DotNpcSpawner) -> void:
	_spawner = spawner


func reset() -> void:
	_queue.clear()
	_pending.clear()


func path_toward(npc: DotNpcInstance, path: DotNpcPath, goal: Vector3) -> Vector3:
	var s := _spawner

	if not s.has_nav() or npc == null or not npc.is_alive() or path == null:
		return goal

	var drift := s.repath_drift
	var interval := s.repath_interval

	if s.repath_drift_ratio > 0.0 or s.repath_interval_per_m > 0.0:
		var gap := npc.position().distance_to(goal)
		drift = maxf(drift, s.repath_drift_ratio * gap)
		interval = maxf(interval, s.repath_interval_per_m * gap)

	var now := s.now()
	var due := path.needs_repath(now, goal, interval, drift)

	if due and (s.deferred_paths or DotParallel.resolve_workers(s.path_workers) > 0):
		_enqueue(npc, path, goal)
	elif due:
		# The filter is set per search, not held on the graph: one graph serves every NPC and a
		# thing that cannot crouch asks a different question of the same points.
		s.nav.filter = filter_for(npc.def)

		var found := (
			s.nav.find_smooth_path(npc.position(), goal, s.limits.spawn_snap_radius,
				s.allow_partial_paths, s.smooth_horizon)
			if s.smooth_paths and not path.is_rough(now)
			else s.nav.find_path(npc.position(), goal, s.limits.spawn_snap_radius,
				s.allow_partial_paths)
		)

		path.set_points(found, now, goal)
		path.partial = s.nav.last_partial

	if path.is_empty():
		return goal

	return path.advance(npc.position(), goal)


func _enqueue(npc: DotNpcInstance, path: DotNpcPath, goal: Vector3) -> void:
	var key := path.get_instance_id()

	if _pending.has(key):
		return

	var s := _spawner
	_pending[key] = true
	var q := DotNpcNavGraph.PathQuery.new()
	q.from = npc.position()
	q.to = goal
	q.filter = filter_for(npc.def)
	q.snap_radius = s.limits.spawn_snap_radius
	q.allow_partial = s.allow_partial_paths
	q.smooth = s.smooth_paths and not path.is_rough(s.now())
	q.horizon = s.smooth_horizon
	_queue.append([path, q, goal])


func answer() -> void:
	if _queue.is_empty():
		return

	var queue := _queue
	_queue = []
	_pending.clear()

	if not _spawner.has_nav():
		return

	var queries: Array = []

	for entry: Array in queue:
		queries.append(entry[1])

	_spawner.nav.find_paths(queries, _spawner.path_workers)

	for entry: Array in queue:
		var path: DotNpcPath = entry[0]
		var q: DotNpcNavGraph.PathQuery = entry[1]
		path.set_points(q.points, _spawner.now(), entry[2])
		path.partial = q.partial


## Cached because it is otherwise rebuilt on every repath, for contents that never change after load.
func filter_for(def: DotNpcDef) -> DotNpcNavFilter:
	if def == null or def.nav_exclude_flags == 0:
		return null

	if _filters.has(def.id):
		return _filters[def.id]

	var filter := DotNpcNavFilter.new()
	filter.exclude_flags = def.nav_exclude_flags
	_filters[def.id] = filter

	return filter
