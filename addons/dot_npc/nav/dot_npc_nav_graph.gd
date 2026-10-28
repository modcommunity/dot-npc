class_name DotNpcNavGraph
extends RefCounted

## A* over a [DotNpcNavData] point graph, plus the funnel a follower actually walks.
## Not NavigationServer3D: code-built maps have nothing to bake, so the data is a graph (see [DotNpcNavData]).
## The adjacency index is built once and reused, since ninety NPCs repathing would otherwise rebuild it per query.

# No log channel: a search. A path that is not found is an answer, asked for several NPCs
# a second, and the caller decides what it means; adopting or refusing the graph for a
# map is logged by DotNpcSpawner.set_nav_data, which is where it enters the process.

var data: DotNpcNavData = null

## Which points this searcher may use and what they cost it.
## Null means no filtering, which is marginally cheaper than a neutral filter; most NPCs have nothing to say.
var filter: DotNpcNavFilter = null

## Whether the last [method find_path] reached the goal or gave up short of it.
## Like Detour's partial result: a brain that cannot tell keeps repathing to something unreachable for ever.
var last_partial: bool = false

## Point index -> Array[int] of neighbouring point indices.
var _adjacency: Dictionary = {}

## How many A* searches have run. For a console command asking why the tick is long.
var searches: int = 0

## How many of those failed to reach the goal.
var failures: int = 0

## Whether [method find_path] searches with Godot's [AStar3D] (native) rather than the script A* in [method _search]. On by default.
## Measured: on 15-18 thousand points the script search was 3 ms a path and over half the server's tick; native is 0.1 ms.
## The script search stays as the test reference. Equal-cost routes may differ between the two; both are deterministic.
var use_native_search: bool = true

## One [AStar3D] per filter signature (see [method _native_for]), built on first use.
var _native: Dictionary = {}

## Filter signature -> {of, list}: the per-worker copies of [member _native] (see [method find_paths]).
var _copies: Dictionary = {}


## Point index -> [expires_at, factor]: places where a walker stalled, costed up for everybody until they expire.
var _bad: Dictionary = {}


## Makes arriving at the point nearest [param at] cost [param factor] times as much until [param until] (the caller's clock), so
## every later search goes round it when it can. Returns the point's index, or -1 when none is within [param radius].
func mark_bad(at: Vector3, until: float, factor: float = 6.0, radius: float = 1.5) -> int:
	if data == null:
		return -1

	var index := data.nearest_point(at, radius)

	if index < 0:
		return -1

	var old := float((_bad[index] as Array)[1]) if _bad.has(index) else 1.0
	_bad[index] = [until, factor]
	_apply_bad(index, old, factor)
	return index


## Forgets the penalties that ran out by [param now].
func expire_bad(now: float) -> void:
	for index: int in _bad.keys():
		if float((_bad[index] as Array)[0]) <= now:
			var old := float((_bad[index] as Array)[1])
			var _gone := _bad.erase(index)
			_apply_bad(index, old, 1.0)


## How many places are costed up right now.
func bad_count() -> int:
	return _bad.size()


# The cached searches carry the weight (each has its own filter's cost in it, so scale by the change).
func _apply_bad(index: int, old: float, factor: float) -> void:
	var lists: Array = []

	for key: String in _native:
		lists.append(_native[key])

	for key: String in _copies:
		lists.append_array((_copies[key] as Dictionary)["list"])

	for astar: AStar3D in lists:
		if astar.has_point(index):
			astar.set_point_weight_scale(index, astar.get_point_weight_scale(index) / old * factor)


func _init(p_data: DotNpcNavData = null) -> void:
	if p_data != null:
		rebuild(p_data)


## Adopts [param p_data] and builds the adjacency index.
func rebuild(p_data: DotNpcNavData) -> DotResult:
	data = p_data
	_adjacency.clear()

	if data == null:
		return DotResult.fail(DotError.CODE_INVALID, "No navigation data.")

	var valid := data.validate()

	if not valid.ok:
		return valid.wrap("Navigation data is not usable.")

	for i in data.points.size():
		_adjacency[i] = PackedInt32Array()

	var pairs := data.edges.size() / 2

	for pair in pairs:
		var a := data.edges[pair * 2]
		var b := data.edges[pair * 2 + 1]

				# Both directions: the edge list is undirected, and one direction gives an NPC that walks in and not out.
				# Read, append, WRITE BACK: a PackedInt32Array is a value type, so `_adjacency[a]` is a copy and
				# appending to it appends to nothing (every edge present, `find_path` empty for every pair).
		var from_a: PackedInt32Array = _adjacency[a]
		from_a.append(b)
		_adjacency[a] = from_a

		var from_b: PackedInt32Array = _adjacency[b]
		from_b.append(a)
		_adjacency[b] = from_b

	_label_components()
	return DotResult.success(self)


## Which connected piece of the graph each point is in, by flood fill. Filter-blind: an NPC
## whose filter cuts a piece in two still gets the right answer from [method _search], just
## not this shortcut.
var _component: PackedInt32Array = PackedInt32Array()


func _label_components() -> void:
	_component = PackedInt32Array()
	_component.resize(data.points.size())
	_component.fill(-1)
	var label := 0

	for seed_index in data.points.size():
		if _component[seed_index] >= 0:
			continue

		var stack := PackedInt32Array([seed_index])
		_component[seed_index] = label

		while not stack.is_empty():
			var at := stack[stack.size() - 1]
			stack.resize(stack.size() - 1)

			for next in neighbours(at):
				if _component[next] < 0:
					_component[next] = label
					stack.append(next)

		label += 1


## Whether two points are in the same connected piece of the graph.
func connected(a: int, b: int) -> bool:
	if a < 0 or b < 0 or a >= _component.size() or b >= _component.size():
		return false

	return _component[a] == _component[b]


## The point in [param start]'s piece of the graph nearest [param to]: where a partial path to
## an unreachable goal ends. The same point a full search would have stopped at, found without
## searching everything the start can reach.
func _nearest_in_component(start: int, to: Vector3) -> int:
	var label := _component[start]
	var radius := maxf(data.spacing(), 1.0) * 2.0

	while radius < 4096.0:
		var best := -1
		var best_sq := INF

		for index in data.points_within(to, radius):
			if _component[index] != label:
				continue

			if filter != null and not filter.passes(data.area_of(index), data.flags_of(index)):
				continue

			var d := data.points[index].distance_squared_to(to)

			if d < best_sq or (d == best_sq and index < best):
				best_sq = d
				best = index

		if best >= 0:
			return best

		radius *= 2.0

	return start


func is_ready() -> bool:
	return data != null and not _adjacency.is_empty()


func neighbours(index: int) -> PackedInt32Array:
	var found: Variant = _adjacency.get(index)
	return found if found is PackedInt32Array else PackedInt32Array()


## A path of world positions from [param from] to [param to], ends included.
## Empty when either end is off the graph or the goal is unreachable, which is not "stand still":
## fall back to steering straight at the target (it often stands where the generator put no point).
func find_path(
	from: Vector3,
	to: Vector3,
	snap_radius: float = -1.0,
	allow_partial: bool = false
) -> PackedVector3Array:
	var astar: AStar3D = _native_for(filter) if use_native_search and is_ready() else null
	var answer := _plan(from, to, snap_radius, allow_partial, astar)
	last_partial = answer.partial
	searches += answer.searches
	failures += answer.failures
	return answer.points


## One search's outcome: what [method find_path] returns and the counters it adds, kept apart
## so a search on a worker writes nothing shared.
class PathAnswer:
	extends RefCounted
	var points := PackedVector3Array()
	var partial := false
	var searches := 0
	var failures := 0


## One repath asked of [method find_paths]. The answer is written into [member points] and
## [member partial] on the calling thread.
class PathQuery:
	extends RefCounted
	var from := Vector3.ZERO
	var to := Vector3.ZERO
	var filter: DotNpcNavFilter = null
	var snap_radius := -1.0
	var allow_partial := false
	## Smoothed as [method find_smooth_path] does, to [member horizon] points.
	var smooth := false
	var horizon := 0
	var points := PackedVector3Array()
	var partial := false


## [method find_path] (or [method find_smooth_path]) for every query, [param workers] at a time on [DotParallel],
## each worker on its own native search. Answers equal the one-at-a-time calls; 0, the script search or no
## threads runs inline in order. Updates [member searches] and [member failures]; [member filter] is restored.
func find_paths(queries: Array, workers: int) -> void:
	if queries.is_empty():
		return

	if not is_ready():
		for q: PathQuery in queries:
			q.points = PackedVector3Array()
			q.partial = false
		return

	data.build_index()
	var n := DotParallel.resolve_workers(workers) if use_native_search else 0
	var groups: Array = []
	var group_of: Dictionary = {}

	for q: PathQuery in queries:
		var key: Variant = q.filter.get_instance_id() if q.filter != null else 0
		if not group_of.has(key):
			group_of[key] = groups.size()
			groups.append([])
		(groups[group_of[key]] as Array).append(q)

	var kept := filter

	# Grouped by filter so [member filter] is fixed while tasks read it: snapping, smoothing and
	# a subclass's [method neighbours] all ask it.
	for group: Array in groups:
		filter = (group[0] as PathQuery).filter
		var engines: Array = _native_copies(filter, maxi(n, 1)) if use_native_search else [null]
		var chunks := mini(engines.size(), group.size())
		var size := ceili(float(group.size()) / chunks)
		# The leg memo is one dictionary, so only an inline run may write it.
		var legs: Variant = _leg_memo(-1.0) if n <= 0 else null
		var task := func(c: int) -> Array:
			var out: Array = []
			for i in range(c * size, mini(group.size(), (c + 1) * size)):
				var q: PathQuery = group[i]
				var a := _plan(q.from, q.to, q.snap_radius, q.allow_partial, engines[c])
				if q.smooth and a.points.size() > 2:
					a.points = _smooth(a.points, -1.0, 8, q.horizon, legs)
				out.append(a)
			return out
		var slots := DotParallel.run(task, chunks, &"npc.paths", n)

		for c in chunks:
			var answers: Array = slots[c]
			for k in answers.size():
				var q: PathQuery = group[c * size + k]
				var a: PathAnswer = answers[k]
				q.points = a.points
				q.partial = a.partial
				searches += a.searches
				failures += a.failures

	filter = kept


## [method find_path]'s search, writing only the answer it returns, so a worker may run it.
## [param astar] is this filter's native search (one thread at a time), or null for the script A*.
func _plan(from: Vector3, to: Vector3, snap_radius: float, allow_partial: bool, astar: AStar3D) -> PathAnswer:
	var answer := PathAnswer.new()

	if not is_ready():
		return answer

	var start := _nearest_passable(from, snap_radius)
	var goal := _nearest_passable(to, snap_radius)

	if start < 0 or goal < 0:
		return answer

	answer.searches += 1
	var out := answer.points

	if start == goal:
		out.append(from)
		out.append(to)
		answer.points = out
		return answer

	# A goal in another piece of the graph cannot be reached, and finding that out by search
	# visits every point the start can reach. Straight to the partial answer instead.
	if filter == null and not _component.is_empty() and not connected(start, goal):
		answer.failures += 1

		if not allow_partial:
			return answer

		var nearest := _nearest_in_component(start, to)

		if nearest == start:
			return answer

		var inner := _plan(from, data.points[nearest], snap_radius, false, astar)
		answer.searches += inner.searches
		answer.failures += inner.failures
		answer.partial = true
		var partial := inner.points

		if partial.size() > 0:
			partial.remove_at(partial.size() - 1)

		answer.points = partial
		return answer

	if astar != null:
		_find_native(from, to, start, goal, allow_partial, astar, answer)
		return answer

	var result := _search(start, goal)
	var came_from: Dictionary = result["came_from"]
	var reached := bool(result["reached"])

	if not reached:
		answer.failures += 1

		# Detour returns a partial path to the closest node it managed to reach: walking to the
		# near side of the wall beats standing still.
		if not allow_partial:
			return answer

		goal = int(result["best"])

		if goal == start:
			return answer

		answer.partial = true

	# Walked backwards from the goal and then reversed: the search records where each point
	# was reached FROM, so the chain only runs in that direction.
	var chain := PackedInt32Array()
	var walk := goal

	while walk != start:
		chain.append(walk)
		var previous: Variant = came_from.get(walk)

		if previous == null:
			answer.failures += 1
			answer.points = PackedVector3Array()
			return answer

		walk = int(previous)

	chain.append(start)
	chain.reverse()

	# The caller's own ends, not the graph points nearest them, or an NPC walks back to the node
	# before setting off; and never the goal on a partial path, which would lead through the wall.
	out.append(from)

	for i in chain:
		out.append(data.points[i])

	if not answer.partial:
		out.append(to)

	answer.points = out
	return answer


## [method _plan]'s search and assembly in [param astar]. [param start] and [param goal] are
## already snapped, distinct and in one component (or a filter is set).
func _find_native(from: Vector3, to: Vector3, start: int, goal: int, allow_partial: bool, astar: AStar3D, answer: PathAnswer) -> void:
	var out := PackedVector3Array()
	var chain := astar.get_id_path(start, goal, allow_partial)

	if chain.is_empty() or chain[0] != start:
		answer.failures += 1
		return

	if chain[chain.size() - 1] != goal:
		# Short of the goal: what the script search calls its best point. As there, a partial
		# path is only handed out when asked for, and never with the goal on its end.
		answer.failures += 1

		if not allow_partial or chain.size() < 2:
			return

		answer.partial = true

	out.append(from)

	for i in chain:
		out.append(data.points[i])

	if not answer.partial:
		out.append(to)

	answer.points = out


## [param count] native searches for [param with], each built exactly as [method _native_for]
## builds it (a subclass's links included), so any of them answers as the cached one does.
## Rebuilt when the cached one is (a subclass that adds links clears [member _native]).
func _native_copies(with: DotNpcNavFilter, count: int) -> Array:
	var original := _native_for(with)
	var key := _native_key(with)
	var entry: Dictionary = _copies.get(key, {})

	if int(entry.get("of", 0)) != original.get_instance_id():
		entry = {"of": original.get_instance_id(), "list": [original]}
		_copies[key] = entry

	var list: Array = entry["list"]

	while list.size() < count:
		_native.erase(key)
		list.append(_native_for(with))
		_native[key] = original

	return list.slice(0, count)


## The [AStar3D] for [param with]: every point, its arrival weight, filtered points disabled.
## Kept per filter signature (flags, costs, graph size), not per object, because a spawner hands over
## a filter per kind and a game may build a fresh one each search.
func _native_for(with: DotNpcNavFilter) -> AStar3D:
	var key := _native_key(with)
	var found: Variant = _native.get(key)

	if found != null:
		return found

	var astar := AStar3D.new()
	var n := data.points.size()
	astar.reserve_space(n)

	for i in n:
		var weight := 1.0

		if with != null:
			weight = with.cost_multiplier(data.area_of(i), data.flags_of(i))

		if _bad.has(i):
			weight *= float((_bad[i] as Array)[1])

		astar.add_point(i, data.points[i], weight)

		if with != null and not with.passes(data.area_of(i), data.flags_of(i)):
			astar.set_point_disabled(i, true)

	# The adjacency's order, which is the edge list's: connecting in the same order as the
	# script search reads its neighbours keeps a tie as close to its choice as it can be.
	for i in n:
		for next in neighbours(i):
			if next > i:
				astar.connect_points(i, next, true)

	_native[key] = astar
	return astar


func _native_key(with: DotNpcNavFilter) -> String:
	var key := "-" if with == null else "%d|%d|%s|%s" % [with.include_flags, with.exclude_flags, with.avoid_cost, with.area_costs]
	return key + "|%d|%d" % [data.points.size(), data.edges.size()]


## The nearest point this searcher is allowed to stand on.
## Not [method DotNpcNavData.nearest_point]: an NPC that cannot crouch at a crouch tunnel's mouth
## would snap onto a point it may not occupy and every path would fail at the first edge.
func _nearest_passable(p: Vector3, radius: float) -> int:
	if filter == null:
		return data.nearest_point(p, radius)

	return data.nearest_point_where(p, radius, _passes_index)


func _passes_index(index: int) -> bool:
	return filter.passes(data.area_of(index), data.flags_of(index))


## Plain A* with a straight-line heuristic.
## Returns [code]{came_from, reached, best}[/code]; best is the closest point to the goal, which a partial path is built from.
## A dictionary, not arrays sized to the graph: this runs when an NPC repaths, not every tick.
func _search(start: int, goal: int) -> Dictionary:
	var goal_position := data.points[goal]

	var came_from := {}
	var cost_so_far := {start: 0.0}

	var best_node := start
	var best_heuristic := goal_position.distance_to(data.points[start])
	var closed := {}

		# The open list is a binary heap of [priority, index], ordered by priority then push order, so
		# equal priorities come out as the old linear scan took them. The scan was most of a tick with
		# a horde of forty repathing on maps of several thousand points.
	var open := _Heap.new()
	open.push(goal_position.distance_to(data.points[start]), start)

	while not open.is_empty():
		var current := open.pop()

		# A node pushed twice (found again by a cheaper route) is expanded once: the
		# cheaper copy came out first, and the stale one is skipped here.
		if closed.has(current):
			continue

		closed[current] = true

		if current == goal:
			return {"came_from": came_from, "reached": true, "best": goal}

		var here := data.points[current]

		for next in neighbours(current):
			if filter != null and not filter.passes(
				data.area_of(next), data.flags_of(next)
			):
				continue

			var step := here.distance_to(data.points[next])

						# Step cost is length times what the destination is made of, charged on arrival, so one
						# expensive tile in the middle of cheap ground costs something.
			if filter != null:
				step *= filter.cost_multiplier(
					data.area_of(next), data.flags_of(next)
				)

			if _bad.has(next):
				step *= float((_bad[next] as Array)[1])

			var new_cost := float(cost_so_far[current]) + step

			if cost_so_far.has(next) and new_cost >= float(cost_so_far[next]):
				continue

			cost_so_far[next] = new_cost
			came_from[next] = current

			var heuristic := goal_position.distance_to(data.points[next])

			# Tracked on every node the search reaches rather than only on the ones it
			# expands, so a goal walled off behind one impassable tile still yields the
			# point on the near side of it.
			if heuristic < best_heuristic:
				best_heuristic = heuristic
				best_node = next

			open.push(new_cost + heuristic, next)

	return {"came_from": came_from, "reached": false, "best": best_node}


## Whether a path exists at all. Cheaper to ask than to walk the result away.
func is_reachable(from: Vector3, to: Vector3, snap_radius: float = -1.0) -> bool:
	return not find_path(from, to, snap_radius).is_empty()



## Whether an NPC can walk straight from [param a] to [param b].
## A point graph has no polygons to raycast, so the corridor is sampled. Stricter than a raycast at a
## doorway, deliberately: a wrong "yes" walks into a wall, a wrong "no" costs one corner.
func can_walk_straight(a: Vector3, b: Vector3, corridor: float = -1.0) -> bool:
	if not is_ready():
		return false

	var width := data.point_radius if corridor < 0.0 else corridor
		# No wider than three quarters of a cell: at the point radius a sample beside a corner snapped to a
		# point across it and smoothing cut corners the graph goes round.
	if data.grid_spacing > 0.0:
		width = minf(width, data.grid_spacing * 0.75)
	var distance := a.distance_to(b)

	if distance <= 0.001:
		return true

		# Connectivity, not proximity: "every sample is near some point" passes through a wall thin enough
		# to have points on both sides. The builder refused to connect points across an obstacle, so ask
		# whether the line stays inside the edges it drew; that is exact rather than a threshold.
	var step := maxf(data.spacing() * 0.4, 0.05)
	var steps := maxi(int(ceil(distance / step)), 1)

	var previous := _nearest_passable(a, width)
	if previous < 0:
		return false

	for i in range(1, steps + 1):
		var probe := a.lerp(b, float(i) / float(steps))
		var current := _nearest_passable(probe, width)

		if current < 0:
			return false

		if current == previous:
			continue

		# Sampled at under half a cell, so the nearest point can only move to a
		# neighbouring cell. If it moved somewhere the builder refused to connect,
		# the line crossed something.
		if not _are_neighbours(previous, current):
			return false

		previous = current

	return true


func _are_neighbours(a: int, b: int) -> bool:
	for n in neighbours(a):
		if n == b:
			return true
	return false


## Removes the corners a grid put in a path: from each kept waypoint, drop everything up to the furthest one
## reachable in a line. [param lookahead] bounds the tests; [param horizon] above 0 smooths only the first points.
func smooth_path(
	path: PackedVector3Array, corridor: float = -1.0, lookahead: int = 8, horizon: int = 0
) -> PackedVector3Array:
	return _smooth(path, corridor, lookahead, horizon, _leg_memo(corridor) if path.size() > 2 else null)


func _smooth(path: PackedVector3Array, corridor: float, lookahead: int, horizon: int, legs: Variant) -> PackedVector3Array:
	if path.size() <= 2:
		return path

	var out := PackedVector3Array()
	out.append(path[0])

	var anchor := 0
	var stop := path.size() - 1 if horizon <= 0 else mini(horizon, path.size() - 1)

	while anchor < stop:
		var furthest := anchor + 1
		var limit := mini(anchor + maxi(lookahead, 1), path.size() - 1)

		for candidate in range(limit, anchor + 1, -1):
			if _leg_walkable(legs, path[anchor], path[candidate], corridor):
				furthest = candidate
				break

		out.append(path[furthest])
		anchor = furthest

	for rest in range(anchor + 1, path.size()):
		out.append(path[rest])

	return out


## Whether [method smooth_path] remembers each leg's [method can_walk_straight] answer. A crowd
## chasing one target smooths the same legs over and over; a subclass whose answer changes without
## the graph or the filter changing must turn this off.
var memo_legs: bool = true

## Legs remembered per filter graph before the memo starts again, so it cannot grow without end.
const LEG_MEMO_MAX := 40000


## The leg memo for the current filter and [param corridor], or null. It lives on that filter's
## [AStar3D], so whatever rebuilds the native graph (a new filter, flags, links) forgets it too.
func _leg_memo(corridor: float) -> Variant:
	if not memo_legs or not use_native_search or not is_ready():
		return null

	var astar := _native_for(filter)
	var key := &"dot_legs" if corridor < 0.0 else StringName("dot_legs_%s" % corridor)
	var memo: Dictionary = astar.get_meta(key, {})

	if memo.is_empty() or int(memo.get(&"count", 0)) > LEG_MEMO_MAX:
		memo = {&"count": 0}
		astar.set_meta(key, memo)

	return memo


func _leg_walkable(memo: Variant, a: Vector3, b: Vector3, corridor: float) -> bool:
	if memo == null:
		return can_walk_straight(a, b, corridor)

	var row: Dictionary = memo.get(a, {})
	var known: Variant = row.get(b)

	if known != null:
		return known

	var walkable := can_walk_straight(a, b, corridor)

	if row.is_empty():
		memo[a] = row
	row[b] = walkable
	memo[&"count"] = int(memo[&"count"]) + 1
	return walkable


## [method find_path] with [method smooth_path] applied. What a follower wants.
func find_smooth_path(
	from: Vector3,
	to: Vector3,
	snap_radius: float = -1.0,
	allow_partial: bool = false,
	horizon: int = 0
) -> PackedVector3Array:
	var path := find_path(from, to, snap_radius, allow_partial)

	if path.size() <= 2:
		return path

	return smooth_path(path, -1.0, 8, horizon)


func describe() -> Dictionary:
	return {
		"map": String(data.map_id) if data != null else "-",
		"filtered": filter != null,
		"points": data.point_count() if data != null else 0,
		"edges": data.edge_count() if data != null else 0,
		"searches": searches,
		"failures": failures,
	}


## A min-heap of (priority, index), with the push order as the tie-break.
class _Heap:
	var _priority: PackedFloat64Array = PackedFloat64Array()
	var _order: PackedInt64Array = PackedInt64Array()
	var _index: PackedInt32Array = PackedInt32Array()
	var _pushed: int = 0

	func is_empty() -> bool:
		return _index.is_empty()

	func push(priority: float, index: int) -> void:
		_priority.append(priority)
		_order.append(_pushed)
		_index.append(index)
		_pushed += 1

		var at := _index.size() - 1

		while at > 0:
			var parent := (at - 1) >> 1

			if not _less(at, parent):
				break

			_swap(at, parent)
			at = parent

	func pop() -> int:
		var top := _index[0]
		var last := _index.size() - 1
		_swap(0, last)
		_priority.resize(last)
		_order.resize(last)
		_index.resize(last)

		var at := 0

		while true:
			var left := at * 2 + 1
			var right := left + 1
			var smallest := at

			if left < last and _less(left, smallest):
				smallest = left
			if right < last and _less(right, smallest):
				smallest = right
			if smallest == at:
				break

			_swap(at, smallest)
			at = smallest

		return top

	func _less(a: int, b: int) -> bool:
		if _priority[a] != _priority[b]:
			return _priority[a] < _priority[b]
		return _order[a] < _order[b]

	func _swap(a: int, b: int) -> void:
		var p := _priority[a]
		_priority[a] = _priority[b]
		_priority[b] = p
		var o := _order[a]
		_order[a] = _order[b]
		_order[b] = o
		var i := _index[a]
		_index[a] = _index[b]
		_index[b] = i
