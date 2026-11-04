class_name DotNpcNavPrune
extends RefCounted

## [method DotNpcNavData.prune] with the slack a physics test needs to keep a map joined: a blocked point slides
## clear, a level change may fall straight down a column beside its line, and a looser body test may join
## pieces the strict test split. Assign the Callables, then [method apply]. Main thread when they query physics.

## `func(p: Vector3) -> bool`: true where a body cannot stand.
var point_blocked: Callable
## `func(a: Vector3, b: Vector3) -> bool`: true where a body cannot walk from a to b.
var edge_blocked: Callable
## The same two tests for the body without its safety margin. Unset, nothing is kept loosely.
## What only these pass is kept only where it joins two pieces the strict tests left apart.
var loose_point_blocked: Callable
var loose_edge_blocked: Callable
## Metres a blocked point may slide to a spot the strict test passes; 0 drops it where it stands.
var nudge := 0.0
## An edge rising or falling more than this may also be crossed by walking to a column, dropping or
## climbing it and walking on: a straight line from a ledge to the floor below cuts through the ledge.
var climb := INF
## How far from either end that column may be.
var column_reach := 1.0

## What the last [method apply] did beyond dropping: points slid, and points and edges kept loosely.
var nudged := 0
var joined_points := 0
var joined_edges := 0

const _NUDGE_STEP := 0.05
const _NUDGE_DIRECTIONS := 16
const _COLUMN_RINGS := [0.5, 0.75, 1.0]
const _COLUMN_DIRECTIONS := 8

enum { _DROP, _STRICT, _LOOSE }


## Prunes [param nav] in place and compacts it. Returns (points dropped, edges dropped), as
## [method DotNpcNavData.prune] does.
func apply(nav: DotNpcNavData) -> Vector2i:
	nav.normalise_arrays()
	nudged = 0
	joined_points = 0
	joined_edges = 0
	var count := nav.points.size()
	var state := PackedInt32Array()
	state.resize(count)
	var moved := nav.points.duplicate()

	for i in count:
		state[i] = _point_state(nav.points[i], moved, i)

	var strict_edges := PackedInt32Array()
	var loose_edges := PackedInt32Array()
	var loose_lengths := PackedFloat32Array()

	for k in range(0, nav.edges.size(), 2):
		var a := nav.edges[k]
		var b := nav.edges[k + 1]

		if state[a] == _DROP or state[b] == _DROP:
			continue

		var both_strict := state[a] == _STRICT and state[b] == _STRICT

		if both_strict and not _blocked(edge_blocked, point_blocked, moved[a], moved[b]):
			strict_edges.append_array([a, b])
		elif _has_loose() and not _blocked(_loose_edge(), _loose_point(), moved[a], moved[b]):
			loose_edges.append_array([a, b])
			loose_lengths.append(moved[a].distance_to(moved[b]))

	var kept_edges := strict_edges + _joining(count, state, strict_edges, loose_edges, loose_lengths)
	return _compact(nav, state, moved, kept_edges)


## True when a body cannot go from [param a] to [param b] by the straight line, nor, for a rise or fall over
## [param climb], by a walk to a column within [param reach] of either end, up or down it, and a walk on.
static func level_change_blocked(edge: Callable, point: Callable, a: Vector3, b: Vector3, climb: float, reach: float = 1.0) -> bool:
	if not edge.is_valid() or not bool(edge.call(a, b)):
		return false

	if absf(a.y - b.y) <= climb:
		return true

	var high := a if a.y > b.y else b
	var low := b if a.y > b.y else a

	for column in _columns(high, low, reach):
		var top := Vector3(column.x, high.y, column.z)
		var bottom := Vector3(column.x, low.y, column.z)

		if point.is_valid() and (bool(point.call(top)) or bool(point.call(bottom))):
			continue

		if _leg_blocked(edge, high, top) or bool(edge.call(top, bottom)) or _leg_blocked(edge, bottom, low):
			continue

		return false

	return true


func _point_state(p: Vector3, moved: PackedVector3Array, i: int) -> int:
	if not point_blocked.is_valid() or not bool(point_blocked.call(p)):
		return _STRICT

	var rings := int(floor(nudge / _NUDGE_STEP + 0.001))

	for ring in range(1, rings + 1):
		for d in _NUDGE_DIRECTIONS:
			var angle := TAU * d / _NUDGE_DIRECTIONS
			var at := p + Vector3(cos(angle), 0.0, sin(angle)) * (ring * _NUDGE_STEP)

			if not bool(point_blocked.call(at)):
				moved[i] = at
				nudged += 1
				return _STRICT

	if _has_loose() and not bool(_loose_point().call(p)):
		return _LOOSE

	return _DROP


func _blocked(edge: Callable, point: Callable, a: Vector3, b: Vector3) -> bool:
	return level_change_blocked(edge, point, a, b, climb, column_reach)


func _has_loose() -> bool:
	return loose_point_blocked.is_valid() or loose_edge_blocked.is_valid()


func _loose_point() -> Callable:
	return loose_point_blocked if loose_point_blocked.is_valid() else point_blocked


func _loose_edge() -> Callable:
	return loose_edge_blocked if loose_edge_blocked.is_valid() else edge_blocked


## The loose edges that join pieces the strict ones left apart, shortest first, with loose points left
## hanging off one piece trimmed away: a body squeezes through a gap only to get somewhere.
func _joining(count: int, state: PackedInt32Array, strict_edges: PackedInt32Array, loose_edges: PackedInt32Array, lengths: PackedFloat32Array) -> PackedInt32Array:
	if loose_edges.is_empty():
		for i in count:
			if state[i] == _LOOSE:
				state[i] = _DROP
		return PackedInt32Array()

	var parent := PackedInt32Array()
	parent.resize(count)
	for i in count:
		parent[i] = i
	for k in range(0, strict_edges.size(), 2):
		_union(parent, strict_edges[k], strict_edges[k + 1])

	var order := range(lengths.size())
	order.sort_custom(func(x: int, y: int) -> bool: return lengths[x] < lengths[y])
	var accepted: Array[int] = []
	var degree := PackedInt32Array()
	degree.resize(count)

	for e: int in order:
		var a := loose_edges[e * 2]
		var b := loose_edges[e * 2 + 1]
		if _union(parent, a, b):
			accepted.append(e)
			degree[a] += 1
			degree[b] += 1

	var trimming := true
	while trimming:
		trimming = false
		for n in accepted.size():
			var e := accepted[n]
			if e < 0:
				continue
			var a := loose_edges[e * 2]
			var b := loose_edges[e * 2 + 1]
			if (state[a] == _LOOSE and degree[a] <= 1) or (state[b] == _LOOSE and degree[b] <= 1):
				degree[a] -= 1
				degree[b] -= 1
				accepted[n] = -1
				trimming = true

	var kept := PackedInt32Array()
	for e in accepted:
		if e >= 0:
			kept.append_array([loose_edges[e * 2], loose_edges[e * 2 + 1]])
	joined_edges = kept.size() / 2

	for i in count:
		if state[i] == _LOOSE:
			if degree[i] > 0:
				joined_points += 1
			else:
				state[i] = _DROP

	return kept


func _compact(nav: DotNpcNavData, state: PackedInt32Array, moved: PackedVector3Array, kept_edges: PackedInt32Array) -> Vector2i:
	var remap := PackedInt32Array()
	remap.resize(nav.points.size())
	var points := PackedVector3Array()
	var areas := PackedInt32Array()
	var flags := PackedInt32Array()

	for i in nav.points.size():
		remap[i] = -1 if state[i] == _DROP else points.size()
		if state[i] != _DROP:
			points.append(moved[i])
			areas.append(nav.areas[i])
			flags.append(nav.flags[i])

	var kept := {}
	var edges := PackedInt32Array()
	for k in range(0, kept_edges.size(), 2):
		kept[Vector2i(mini(kept_edges[k], kept_edges[k + 1]), maxi(kept_edges[k], kept_edges[k + 1]))] = true
		edges.append_array([remap[kept_edges[k]], remap[kept_edges[k + 1]]])

	var cut := PackedVector3Array()
	for k in range(0, nav.edges.size(), 2):
		var a := nav.edges[k]
		var b := nav.edges[k + 1]
		if state[a] == _DROP and state[b] == _DROP:
			continue
		if not kept.has(Vector2i(mini(a, b), maxi(a, b))):
			cut.append_array([nav.points[a], nav.points[b]])

	var dropped := Vector2i(nav.points.size() - points.size(), (nav.edges.size() - edges.size()) / 2)
	nav.points = points
	nav.areas = areas
	nav.flags = flags
	nav.edges = edges
	nav.remember_cut_edges(cut)
	nav.invalidate_index()
	return dropped


static func _union(parent: PackedInt32Array, a: int, b: int) -> bool:
	var ra := _find(parent, a)
	var rb := _find(parent, b)
	if ra == rb:
		return false
	parent[ra] = rb
	return true


static func _find(parent: PackedInt32Array, i: int) -> int:
	while parent[i] != i:
		parent[i] = parent[parent[i]]
		i = parent[i]
	return i


static func _leg_blocked(edge: Callable, a: Vector3, b: Vector3) -> bool:
	return a.distance_squared_to(b) > 1e-6 and bool(edge.call(a, b))


## Where to drop or climb: straight under the high end, straight over the low end, then rings round each.
static func _columns(high: Vector3, low: Vector3, reach: float) -> PackedVector3Array:
	var out := PackedVector3Array([high, low])
	for centre in [high, low]:
		for radius: float in _COLUMN_RINGS:
			if radius > reach + 0.001:
				break
			for d in _COLUMN_DIRECTIONS:
				var angle := TAU * d / _COLUMN_DIRECTIONS
				out.append(centre + Vector3(cos(angle), 0.0, sin(angle)) * radius)
	return out
