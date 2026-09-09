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
func find_path(from: Vector3, to: Vector3, snap_radius: float = -1.0) -> PackedVector3Array:
	var out := PackedVector3Array()

	if not is_ready():
		return out

	var start := data.nearest_point(from, snap_radius)
	var goal := data.nearest_point(to, snap_radius)

	if start < 0 or goal < 0:
		return out

	searches += 1

	if start == goal:
		out.append(from)
		out.append(to)
		return out

	var came_from := _search(start, goal)

	if came_from.is_empty():
		failures += 1
		return out

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

	out.append(to)

	return out


## Plain A* with a straight-line heuristic. Returns point -> point it was reached from.
##
## A dictionary rather than arrays sized to the graph, because a graph is a few
## hundred points and this runs when an NPC repaths rather than every tick.
func _search(start: int, goal: int) -> Dictionary:
	var goal_position := data.points[goal]

	var came_from := {}
	var cost_so_far := {start: 0.0}

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
			return came_from

		var here := data.points[current]

		for next in neighbours(current):
			var step := here.distance_to(data.points[next])
			var new_cost := float(cost_so_far[current]) + step

			if cost_so_far.has(next) and new_cost >= float(cost_so_far[next]):
				continue

			cost_so_far[next] = new_cost
			came_from[next] = current
			open.append([
				new_cost + goal_position.distance_to(data.points[next]), next
			])

	return {}


## Whether a path exists at all. Cheaper to ask than to walk the result away.
func is_reachable(from: Vector3, to: Vector3, snap_radius: float = -1.0) -> bool:
	return not find_path(from, to, snap_radius).is_empty()


func describe() -> Dictionary:
	return {
		"map": String(data.map_id) if data != null else "-",
		"points": data.point_count() if data != null else 0,
		"edges": data.edge_count() if data != null else 0,
		"searches": searches,
		"failures": failures,
	}
