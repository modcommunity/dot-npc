extends "res://examples/selftest/replication_tests.gd"

## The path-worker checks of npc_selftest.gd that run on their own data: shared native state, deferred_paths
## runs at 0 and 4 workers, and the web fallback. Split out to keep npc_selftest.gd under the size gate.


## Web, or no threads: the same setting resolves to 0 and path_toward searches inline.
func _check_web_inline(spawners: Array[DotNpcSpawner]) -> void:
	# Web, or no threads: the same setting resolves to 0 and path_toward searches inline.
	DotPlatform._kind = DotPlatform.Kind.WEB
	var web_workers := DotParallel.resolve_workers(4)
	var web_npc := spawners[1].spawn(&"walker", Vector3(-10, 0, -10))
	var web_path := DotNpcPath.new()
	spawners[1].path_toward(web_npc, web_path, Vector3(10, 0, 10))
	DotPlatform._kind = -1
	_check(web_workers == 0, "on the web sv_threads_npc resolves to 0 workers")
	_check(not web_path.is_empty(), "and path_toward finds the path inline there")
	_check(spawners[1].describe().has("path_workers"), "describe() reports the path workers")


## deferred_paths: queued at any worker count, so a run is the same run at 0 and 4 workers.
func _check_deferred_paths(data: DotNpcNavData, queries: Array, threaded: bool) -> void:
	# deferred_paths: queued at any worker count, so a run is the same run at 0 and 4 workers.
	var deferred_off := _deferred_run(data, queries, 0)
	var deferred_on := _deferred_run(data, queries, 4)
	var deferred_again := _deferred_run(data, queries, 0)
	_check(deferred_off[1], "deferred_paths queues the repath even at path_workers 0")
	_check(deferred_off[2] > 12, "and the run repaths many times", "%d searches" % deferred_off[2])
	_check(deferred_off[0] == deferred_again[0], "deferred, 0 workers twice: the same hash",
		"%d vs %d" % [deferred_off[0], deferred_again[0]])
	_check(deferred_on[0] == deferred_off[0] and deferred_on[2] == deferred_off[2],
		"deferred, 4 workers against 0: the same hash and searches",
		"%d vs %d, %d vs %d searches%s" % [deferred_on[0], deferred_off[0], deferred_on[2], deferred_off[2],
			"" if threaded else " (no threads here: inline)"])


## find_paths' shared state: a mark_bad reaches every native copy once, and the cut index is built before the workers start.
func _check_copies_and_cut_index(graph: DotNpcNavGraph, builder: DotNpcNavBuilder) -> void:
	# A costed-up point after the copies exist: every engine (the original is also first in its
	# copies list) carries the factor once, so worker 0 and worker 3 answer alike.
	var bad := graph.mark_bad(Vector3(0, 0, 0), INF, 6.0, 3.0)
	var scales: Array = []

	# The unfiltered engines: weight 1 everywhere, so 6 after the mark.
	for astar: AStar3D in (graph._copies[graph._native_key(null)] as Dictionary)["list"]:
		scales.append(snappedf(astar.get_point_weight_scale(bad), 0.001))

	_check(bad >= 0 and (scales.size() > 1 or DotParallel.resolve_workers(4) == 0) and scales.all(func(w: float) -> bool: return w == 6.0),
		"mark_bad scales every native copy once, the original included", str(scales))

	# Smoothing on workers asks crosses_cut; its index was built lazily on whichever thread asked
	# first, and two workers building it at once crashed ZZ. find_paths builds it before they start.
	var cut_data := builder.build(&"workers_cut", "digest")
	cut_data.remember_cut_edges(PackedVector3Array([Vector3(30, 0, -4), Vector3(30, 0, 4)]))
	var cut_graph := DotNpcNavGraph.new(cut_data)
	var lazy: bool = cut_graph._line._cut_indexed
	var cut_q := DotNpcNavGraph.PathQuery.new()
	cut_q.from = Vector3(-18, 0, -18)
	cut_q.to = Vector3(40, 0, 0)
	cut_q.snap_radius = 3.0
	# Unsmoothed, so nothing on a worker asks crosses_cut: only prepare can have built the index.
	cut_q.smooth = false
	cut_graph.find_paths([cut_q], 4)
	_check(not lazy and cut_graph._line._cut_indexed and not cut_graph._line._cut_index.is_empty(),
		"find_paths builds the cut index before its workers smooth", "%s then %s" % [lazy, cut_graph._line._cut_indexed])
	graph.expire_bad(INF)


## Returns [hash, queued at the first ask, searches] of a seeded walk with [member DotNpcSpawner.deferred_paths].
func _deferred_run(data: DotNpcNavData, queries: Array, workers: int) -> Array:
	var limits := _limits()
	limits.spawn_snap_radius = 3.0
	var spawner := _spawner(limits)
	spawner.set_nav_data(data)
	spawner.deferred_paths = true
	spawner.path_workers = workers
	spawner.repath_interval = 0.5
	var rng := RandomNumberGenerator.new()
	rng.seed = 23
	var npcs: Array = []
	var paths: Array = []
	var goals: Array = []

	for i in 12:
		npcs.append(spawner.spawn(&"walker", (queries[i] as DotNpcNavGraph.PathQuery).from))
		paths.append(DotNpcPath.new())
		goals.append((queries[i] as DotNpcNavGraph.PathQuery).to)

	var h := 0
	var queued := false
	var searches_before := spawner.nav.searches

	for t in 200:
		for i in npcs.size():
			var npc: DotNpcInstance = npcs[i]
			if t % 40 == 0:
				goals[i] = Vector3(rng.randf_range(-18, 44), 0, rng.randf_range(-18, 18))
			var step := spawner.path_toward(npc, paths[i], goals[i])
			if t == 0 and i == 0:
				queued = (paths[i] as DotNpcPath).is_empty()
			var body := npc.node as Node3D
			var flat := Vector3(step.x - body.global_position.x, 0, step.z - body.global_position.z)
			body.global_position += flat.limit_length(0.4)
			h = hash([h, snappedf(body.global_position.x, 0.001), snappedf(body.global_position.z, 0.001)])
		spawner.tick(0.05)

	for p: DotNpcPath in paths:
		h = hash([h, p.points, p.partial])

	var searches := spawner.nav.searches - searches_before
	spawner.queue_free()
	return [h, queued, searches]
