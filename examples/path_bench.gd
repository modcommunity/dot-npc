extends Node

## A crowd repathing in one tick: [method DotNpcNavGraph.find_paths] inline against N workers.
##
## [codeblock]
## godot --headless --path . res://examples/path_bench.tscn -- [--npcs=256] [--workers=4] [--rounds=5] [--nav=<cache file>]
## [/codeblock]
## Without --nav the graph is a generated 180 m square crossed by walls. Prints one RESULT line,
## and exits 1 if any answer differs between the two runs.

var _npcs := 256
var _workers := 4
var _rounds := 5
var _nav_file := ""


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--npcs="):
			_npcs = arg.trim_prefix("--npcs=").to_int()
		elif arg.begins_with("--workers="):
			_workers = arg.trim_prefix("--workers=").to_int()
		elif arg.begins_with("--rounds="):
			_rounds = arg.trim_prefix("--rounds=").to_int()
		elif arg.begins_with("--nav="):
			_nav_file = arg.trim_prefix("--nav=")

	var graph := DotNpcNavGraph.new(_load())
	var pts := graph.data.points
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var queries: Array = []

	for i in _npcs:
		var q := DotNpcNavGraph.PathQuery.new()
		q.from = pts[rng.randi() % pts.size()]
		q.to = pts[rng.randi() % pts.size()]
		q.snap_radius = 2.5
		q.allow_partial = true
		q.smooth = true
		q.horizon = 16
		queries.append(q)

	# Warm both: the native searches (and the workers' copies) are built on first use.
	graph.find_paths(queries.slice(0, 1), 0)
	graph.find_paths(queries.slice(0, 1), _workers)
	var inline := _time(graph, queries, 0)
	var reference: Array = queries.map(func(q: DotNpcNavGraph.PathQuery) -> PackedVector3Array: return q.points)
	var pooled := _time(graph, queries, _workers)
	var differ := 0

	for i in queries.size():
		if (queries[i] as DotNpcNavGraph.PathQuery).points != reference[i]:
			differ += 1

	print("RESULT %s" % JSON.stringify({"points": pts.size(), "npcs": _npcs,
		"workers": DotParallel.resolve_workers(_workers), "inline_ms": inline, "pooled_ms": pooled,
		"speedup": snappedf(inline / maxf(pooled, 0.001), 0.01), "differ": differ}))
	get_tree().quit(1 if differ > 0 else 0)


func _time(graph: DotNpcNavGraph, queries: Array, workers: int) -> float:
	var started := Time.get_ticks_usec()

	for r in _rounds:
		graph.find_paths(queries, workers)

	return snappedf((Time.get_ticks_usec() - started) / float(_rounds) / 1000.0, 0.01)


func _load() -> DotNpcNavData:
	if _nav_file != "":
		var got := DotNpcNavData.from_cache_bytes(FileAccess.get_file_as_bytes(_nav_file))
		if got != null:
			return got

	var builder := DotNpcNavBuilder.new()
	builder.spacing = 2.0
	builder.add_floor(AABB(Vector3(-90, 0, -90), Vector3(180, 0, 180)), 0.0)

	for k in 8:
		builder.add_obstacle(AABB(Vector3(-70 + k * 18, 0, -80 + (k % 2) * 20), Vector3(2, 3, 140)))

	return builder.build(&"bench", "bench")
