class_name DotNpcNavGraph
extends RefCounted

## A* over a [DotNpcNavData] point graph, plus the funnel a follower actually walks.
##
## [b]Why this exists rather than [code]NavigationServer3D[/code].[/b] Godot's own
## navigation is a good answer to a different question: it bakes a mesh from source
## geometry that exists in a scene at edit time. Every map in this family is built in
## code from constants, so at edit time the scene is an empty node with a script and
## there is nothing to bake. The nav data is therefore generated from the same
## constants the geometry was — see [DotNpcNavData] — and what comes out is a graph of
## points, not a polygon soup. A* over that graph is the honest consumer of it.
##
## [b]A game with authored geometry should use Godot's navigation instead, and this
## does not stop it.[/b] Nothing else in dot-npc requires this class: a
## [DotNpcDirector] with no nav data spawns anywhere and a brain that owns a
## [code]NavigationAgent3D[/code] paths with that. This is what a code-built map gets
## so that it is not the one shape of map that cannot have NPCs.
##
## [b]The index is built once and reused.[/b] A* on a hundred-point graph is
## microseconds; rebuilding the adjacency list from a flat [PackedInt32Array] on every
## query is not, and ninety NPCs repathing is exactly when it would be paid.

const CHANNEL := "npc.nav"

var data: DotNpcNavData = null

## Which points this searcher may use and what they cost it.
##
## Null means no filtering at all, which is not the same as a neutral filter and is
## marginally cheaper: one graph serves every NPC on the map, and most of them have
## nothing to say about it.
var filter: DotNpcNavFilter = null

## Whether the last [method find_path] reached the goal or gave up short of it.
##
## Detour reports this as [code]DT_PARTIAL_RESULT[/code] and it is worth having for
## the same reason: an NPC handed a partial path is walking towards something it
## cannot reach, and a brain that cannot tell the difference will keep repathing to it
## for ever.
var last_partial: bool = false

## Point index -> Array[int] of neighbouring point indices.
var _adjacency: Dictionary = {}

## How many A* searches have run. For a console command asking why the tick is long.
var searches: int = 0

## How many of those failed to reach the goal.
var failures: int = 0


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

		# Both directions. The edge list is undirected by declaration, and a graph
		# that recorded only one direction gives an NPC that can walk into a room and
		# not out of it — which reads as a stuck brain rather than as a missing edge.
		#
		# Read, append, WRITE BACK. A PackedInt32Array is a value type in GDScript, so
		# `_adjacency[a]` hands out a copy and appending to it appends to nothing. The
		# first version of this did exactly that, and the symptom is the one this
		# family keeps meeting: every edge was in the data, every count was right, and
		# `find_path` returned empty for every pair of points. Nothing errored, because
		# an empty adjacency list is a legitimate thing for an isolated point to have.
		var from_a: PackedInt32Array = _adjacency[a]
		from_a.append(b)
		_adjacency[a] = from_a

		var from_b: PackedInt32Array = _adjacency[b]
		from_b.append(a)
		_adjacency[b] = from_b

	return DotResult.success(self)


func is_ready() -> bool:
	return data != null and not _adjacency.is_empty()


func neighbours(index: int) -> PackedInt32Array:
	var found: Variant = _adjacency.get(index)
	return found if found is PackedInt32Array else PackedInt32Array()


## A path of world positions from [param from] to [param to], ends included.
##
## Empty when either end is off the graph or the goal is unreachable. [b]Empty is not
## the same as "stand still"[/b] and a caller must not treat it as one: an NPC handed
## an empty path should fall back to steering straight at its target, because the
## commonest cause is a target standing somewhere the generator did not put a point.
func find_path(
	from: Vector3,
	to: Vector3,
	snap_radius: float = -1.0,
	allow_partial: bool = false
) -> PackedVector3Array:
	var out := PackedVector3Array()
	last_partial = false

	if not is_ready():
		return out

	var start := _nearest_passable(from, snap_radius)
	var goal := _nearest_passable(to, snap_radius)

	if start < 0 or goal < 0:
		return out

	searches += 1

	if start == goal:
		out.append(from)
		out.append(to)
		return out

	var result := _search(start, goal)
	var came_from: Dictionary = result["came_from"]
	var reached := bool(result["reached"])

	if not reached:
		failures += 1

		# Detour returns a partial path to the closest node it managed to reach, and
		# an NPC is better off walking to the near side of the wall than standing
		# still: it is what a person does, it puts the NPC where a door might open,
		# and the director's spawn logic reads positions rather than intentions.
		if not allow_partial:
			return out

		goal = int(result["best"])

		if goal == start:
			return out

		last_partial = true

	# Walked backwards from the goal and then reversed, which is the only way round:
	# the search records where each point was reached FROM, so the chain only runs
	# in that direction.
	var chain := PackedInt32Array()
	var walk := goal

	while walk != start:
		chain.append(walk)
		var previous: Variant = came_from.get(walk)

		if previous == null:
			failures += 1
			return PackedVector3Array()

		walk = int(previous)

	chain.append(start)
	chain.reverse()

	# The real start and end are the caller's positions, not the graph points nearest
	# them. Without this an NPC standing beside a node walks BACK to the node before
	# setting off, which looks exactly like a bug and is the first thing anybody
	# watching a path follower notices.
	out.append(from)

	for i in chain:
		out.append(data.points[i])

	# The caller's own goal, except on a partial path — where appending it would put
	# the unreachable position on the end of a path that deliberately stops short, and
	# every follower would walk the last leg straight through the wall.
	if not last_partial:
		out.append(to)

	return out


## The nearest point this searcher is allowed to stand on.
##
## Not [method DotNpcNavData.nearest_point]: that answers "where is the mesh", and a
## filtered search asks "where is the mesh I may use". An NPC that cannot crouch,
## standing at the mouth of a crouch tunnel, would otherwise snap onto a point it may
## not occupy and every path from it would fail at the first edge.
func _nearest_passable(p: Vector3, radius: float) -> int:
	if filter == null:
		return data.nearest_point(p, radius)

	var limit := data.point_radius if radius < 0.0 else radius
	var limit_sq := limit * limit
	var best := -1
	var best_sq := INF

	for i in data.points.size():
		var d_sq := data.points[i].distance_squared_to(p)
		if d_sq >= best_sq or d_sq > limit_sq:
			continue
		if not filter.passes(data.area_of(i), data.flags_of(i)):
			continue
		best_sq = d_sq
		best = i

	return best


## Plain A* with a straight-line heuristic.
##
## Returns [code]{came_from, reached, best}[/code]: where each point was reached from,
## whether the goal was one of them, and the closest point to the goal that was — which
## is what a partial path is built out of.
##
## A dictionary rather than arrays sized to the graph, because a graph is a few
## hundred points and this runs when an NPC repaths rather than every tick.
func _search(start: int, goal: int) -> Dictionary:
	var goal_position := data.points[goal]

	var came_from := {}
	var cost_so_far := {start: 0.0}

	var best_node := start
	var best_heuristic := goal_position.distance_to(data.points[start])

	# An open list kept as a plain Array of [priority, index] and scanned linearly.
	#
	# A binary heap is the textbook answer and is wrong at this size: a hundred-point
	# graph makes the scan a hundred compares, and the heap's own bookkeeping costs
	# more than that. Revisit it if a map ever ships thousands of points — and if one
	# does, the real fix is a coarser graph, not a faster queue.
	var open: Array = [[goal_position.distance_to(data.points[start]), start]]

	while not open.is_empty():
		var best_slot := 0

		for i in range(1, open.size()):
			if float((open[i] as Array)[0]) < float((open[best_slot] as Array)[0]):
				best_slot = i

		var current := int((open[best_slot] as Array)[1])
		open.remove_at(best_slot)

		if current == goal:
			return {"came_from": came_from, "reached": true, "best": goal}

		var here := data.points[current]

		for next in neighbours(current):
			if filter != null and not filter.passes(
				data.area_of(next), data.flags_of(next)
			):
				continue

			var step := here.distance_to(data.points[next])

			# The cost of a step is its length times what the destination is made of.
			# Detour charges the filter per polygon crossed; here the point is the
			# polygon, and charging on arrival rather than departure is what makes a
			# single expensive tile in the middle of cheap ground cost something.
			if filter != null:
				step *= filter.cost_multiplier(
					data.area_of(next), data.flags_of(next)
				)

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

			open.append([new_cost + heuristic, next])

	return {"came_from": came_from, "reached": false, "best": best_node}


## Whether a path exists at all. Cheaper to ask than to walk the result away.
func is_reachable(from: Vector3, to: Vector3, snap_radius: float = -1.0) -> bool:
	return not find_path(from, to, snap_radius).is_empty()


# --- Smoothing ---------------------------------------------------------------

## Whether an NPC can walk straight from [param a] to [param b].
##
## Detour asks its navmesh with a raycast; a point graph has no polygons to cast
## against, so the corridor is sampled instead: every sample must be within reach of a
## point this searcher may use. That is stricter than a raycast at a doorway — a
## diagonal squeeze whose midpoint has no graph point is refused — and being strict is
## the right way round, because the cost of a wrong "yes" is an NPC walking into a
## wall and the cost of a wrong "no" is one extra corner in the path.
func can_walk_straight(a: Vector3, b: Vector3, corridor: float = -1.0) -> bool:
	if not is_ready():
		return false

	var width := data.point_radius if corridor < 0.0 else corridor
	var distance := a.distance_to(b)

	if distance <= 0.001:
		return true

	# [b]Connectivity, not proximity, and the difference is a wall.[/b] The obvious
	# test — "every sample along the line is near some point" — passes straight
	# through any wall thin enough to have graph points on both sides of it, because
	# a sample in the middle of it is within reach of the points beside it. The
	# builder already solved that at generation time: it refused to connect two points
	# whose straight line crossed an obstacle. So the question to ask at runtime is
	# whether the line stays inside the edges the builder drew, and the answer is
	# exact rather than a threshold.
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


## Removes the corners a grid put in a path that the world does not have.
##
## [b]This is the difference between a path and a path anybody believes.[/b] A graph
## on a two-metre grid can only turn in eight directions, so crossing an open room
## comes out as a staircase: an NPC walking it visibly zig-zags across ground with
## nothing in it. Detour solves the polygon version with the funnel algorithm; the
## point-graph version is the same idea reached the other way — walk forward from each
## kept waypoint and drop everything up to the furthest one still reachable in a
## straight line.
##
## Runs in a bounded number of visibility tests rather than the O(n²) the naive
## spelling costs: [param lookahead] caps how far ahead one waypoint may reach.
func smooth_path(
	path: PackedVector3Array, corridor: float = -1.0, lookahead: int = 8
) -> PackedVector3Array:
	if path.size() <= 2:
		return path

	var out := PackedVector3Array()
	out.append(path[0])

	var anchor := 0

	while anchor < path.size() - 1:
		var furthest := anchor + 1
		var limit := mini(anchor + maxi(lookahead, 1), path.size() - 1)

		for candidate in range(limit, anchor + 1, -1):
			if can_walk_straight(path[anchor], path[candidate], corridor):
				furthest = candidate
				break

		out.append(path[furthest])
		anchor = furthest

	return out


## [method find_path] with [method smooth_path] applied. What a follower wants.
func find_smooth_path(
	from: Vector3,
	to: Vector3,
	snap_radius: float = -1.0,
	allow_partial: bool = false
) -> PackedVector3Array:
	var path := find_path(from, to, snap_radius, allow_partial)

	if path.size() <= 2:
		return path

	return smooth_path(path)


func describe() -> Dictionary:
	return {
		"map": String(data.map_id) if data != null else "-",
		"filtered": filter != null,
		"points": data.point_count() if data != null else 0,
		"edges": data.edge_count() if data != null else 0,
		"searches": searches,
		"failures": failures,
	}
