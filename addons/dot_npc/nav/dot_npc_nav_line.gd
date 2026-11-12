class_name DotNpcNavLine
extends RefCounted

## Straight-line walkability over a [DotNpcNavGraph]: the sampled corridor test, the prune's cut edges
## indexed by cell, and the neighbour-sector check. Holds only caches; the graph passes itself in,
## so there is no reference cycle. [method DotNpcNavGraph.can_walk_straight] is the public door.

## Neighbours a point has when every cell round it is walkable (the grid's eight).
const FULL_NEIGHBOURS := 8

## Whether an NPC can walk straight from [param a] to [param b].
## A point graph has no polygons to raycast, so the corridor is sampled. Stricter than a raycast at a
## doorway, deliberately: a wrong "yes" walks into a wall, a wrong "no" costs one corner.
func can_walk_straight(g: DotNpcNavGraph, a: Vector3, b: Vector3, corridor: float = -1.0) -> bool:
	if not g.is_ready():
		return false

	var width := g.data.point_radius if corridor < 0.0 else corridor
		# No wider than three quarters of a cell: at the point radius a sample beside a corner snapped to a
		# point across it and smoothing cut corners the graph goes round.
	if g.data.grid_spacing > 0.0:
		width = minf(width, g.data.grid_spacing * 0.75)
	var distance := a.distance_to(b)

	if distance <= 0.001:
		return true

	if crosses_cut(g, a, b):
		return false

		# Connectivity, not proximity: "every sample is near some point" passes through a wall thin enough
		# to have points on both sides. The builder refused to connect points across an obstacle, so ask
		# whether the line stays inside the edges it drew; that is exact rather than a threshold.
	var step := maxf(g.data.spacing() * 0.4, 0.05)
	var steps := maxi(int(ceil(distance / step)), 1)

	var previous := g._nearest_passable(a, width)
	if previous < 0 or not sample_clear(g, a, previous):
		return false

	for i in range(1, steps + 1):
		var probe := a.lerp(b, float(i) / float(steps))
		var current := g._nearest_passable(probe, width)

		if current < 0 or not sample_clear(g, probe, current):
			return false

		if current == previous:
			continue

		# Sampled at under half a cell, so the nearest point can only move to a
		# neighbouring cell. If it moved somewhere the builder refused to connect,
		# the line crossed something.
		if not are_neighbours(g, previous, current):
			return false

		previous = current

	return true


var _cut_index: Dictionary = {}
## Cells with a cut segment in them or in the eight round them: a line sample elsewhere has nothing to test.
var _cut_near: Dictionary = {}
var _cut_indexed := false
var _surrounded_memo: Dictionary = {}
## [method DotNpcNavGraph.find_paths] smooths on worker threads, and they share the sector memo.
var _memo_lock := Mutex.new()


## Builds the cut index now. [method DotNpcNavGraph.find_paths] calls it before its workers start:
## built lazily on two threads at once, one read a half-filled dictionary and the engine crashed.
func prepare(g: DotNpcNavGraph) -> void:
	if not _cut_indexed:
		_index_cuts(g)


## Whether the line a to b crosses an edge the data's prune cut (physics said a body cannot use it).
## Indexed by cell on first use; a line only meets the segments in the cells it passes through.
func crosses_cut(g: DotNpcNavGraph, a: Vector3, b: Vector3) -> bool:
	if not _cut_indexed:
		_index_cuts(g)

	if _cut_index.is_empty():
		return false

	var cut := g.data.cut_edges()
	var cell := _cut_size(g)
	var steps := maxi(int(ceil(a.distance_to(b) / cell)), 1)
	var seen: Dictionary = {}

	for i in steps + 1:
		var at := a.lerp(b, float(i) / steps)
		var home := _cut_cell(g, at)

		if not _cut_near.has(home):
			continue

		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var key := Vector2i(home.x + dx, home.y + dz)

				if seen.has(key):
					continue

				seen[key] = true

				for k: int in _cut_index.get(key, []):
					if _segments_cross(a, b, cut[k], cut[k + 1]):
						return true

	return false


func _index_cuts(g: DotNpcNavGraph) -> void:
	var all := g.data.cut_edges()
	var index: Dictionary = {}
	var near: Dictionary = {}

	for k in range(0, all.size() - 1, 2):
		var key := _cut_cell(g, (all[k] + all[k + 1]) * 0.5)
		var list: Array = index.get(key, [])
		list.append(k)
		index[key] = list

	for key: Vector2i in index:
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				near[Vector2i(key.x + dx, key.y + dz)] = true

	_cut_index = index
	_cut_near = near
	_cut_indexed = true


func _cut_size(g: DotNpcNavGraph) -> float:
	return maxf(g.data.grid_spacing * 2.0, 1.0)


func _cut_cell(g: DotNpcNavGraph, p: Vector3) -> Vector2i:
	var size := _cut_size(g)
	return Vector2i(floori(p.x / size), floori(p.z / size))


## Whether two segments cross in the ground plane at heights within a metre of each other.
static func _segments_cross(a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> bool:
	var r := Vector2(b.x - a.x, b.z - a.z)
	var s := Vector2(d.x - c.x, d.z - c.z)
	var denom := r.cross(s)

	if absf(denom) < 0.00001:
		return false

	var ca := Vector2(c.x - a.x, c.z - a.z)
	var t := ca.cross(s) / denom
	var u := ca.cross(r) / denom

	if t < 0.0 or t > 1.0 or u < 0.0 or u > 1.0:
		return false

	return absf(lerpf(a.y, b.y, t) - lerpf(c.y, d.y, u)) < 1.0


func sample_clear(g: DotNpcNavGraph, at: Vector3, point: int) -> bool:
	if g.data.grid_spacing <= 0.0:
		return true

	if at.distance_to(g.data.points[point]) <= g.data.grid_spacing * g.straight_width_ratio + 0.01:
		return true

	return _surrounded(g, point)


## Whether the point has a neighbour in every 45 degree sector within two cells. A count cannot tell: extended
## links keep it over [constant FULL_NEIGHBOURS] when a wall took the whole west side, and a line may graze that wall.
func _surrounded(g: DotNpcNavGraph, point: int) -> bool:
	_memo_lock.lock()
	var known: Variant = _surrounded_memo.get(point)
	_memo_lock.unlock()

	if known != null:
		return known

	var here := g.data.points[point]
	var reach := g.data.grid_spacing * 2.0
	var seen := 0

	for n in g.neighbours(point):
		var d := g.data.points[n] - here
		d.y = 0.0

		if d.length() <= reach and d.length() > 0.001:
			seen |= 1 << (int(floor((atan2(d.z, d.x) + PI) / (TAU / FULL_NEIGHBOURS))) % FULL_NEIGHBOURS)

	var full := seen == (1 << FULL_NEIGHBOURS) - 1
	_memo_lock.lock()
	_surrounded_memo[point] = full
	_memo_lock.unlock()
	return full


func are_neighbours(g: DotNpcNavGraph, a: int, b: int) -> bool:
	for n in g.neighbours(a):
		if n == b:
			return true
	return false


## Forgets what a rebuilt graph no longer matches.
func clear() -> void:
	_cut_index.clear()
	_cut_near.clear()
	_cut_indexed = false
	_surrounded_memo.clear()
