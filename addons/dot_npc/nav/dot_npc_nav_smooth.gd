class_name DotNpcNavSmooth
extends RefCounted

## Corner removal for a [DotNpcNavGraph] path and the per-filter memo of legs already tested.
## Static, with the graph passed in; [method DotNpcNavGraph.smooth_path] is the public door.

## Removes the corners a grid put in a path: from each kept waypoint, drop everything up to the furthest one
## reachable in a line. [param lookahead] bounds the tests; [param horizon] above 0 smooths only the first points.
static func smooth_path(
	g: DotNpcNavGraph, path: PackedVector3Array, corridor: float = -1.0, lookahead: int = 8, horizon: int = 0
) -> PackedVector3Array:
	return smooth(g, path, corridor, lookahead, horizon, leg_memo(g, corridor) if path.size() > 2 else null)


static func smooth(g: DotNpcNavGraph, path: PackedVector3Array, corridor: float, lookahead: int, horizon: int, legs: Variant) -> PackedVector3Array:
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
			if leg_walkable(g, legs, path[anchor], path[candidate], corridor):
				furthest = candidate
				break

		out.append(path[furthest])
		anchor = furthest

	for rest in range(anchor + 1, path.size()):
		out.append(path[rest])

	return out


## Drops every remembered leg: the answers depend on [member straight_width_ratio].
static func forget_legs(g: DotNpcNavGraph) -> void:
	for key: String in g._native:
		var astar: AStar3D = g._native[key]
		for meta: StringName in astar.get_meta_list():
			if String(meta).begins_with("dot_legs"):
				astar.remove_meta(meta)


## The leg memo for the current filter and [param corridor], or null. It lives on that filter's
## [AStar3D], so whatever rebuilds the native graph (a new filter, flags, links) forgets it too.
static func leg_memo(g: DotNpcNavGraph, corridor: float) -> Variant:
	if not g.memo_legs or not g.use_native_search or not g.is_ready():
		return null

	var astar := g._native_for(g.filter)
	var key := &"dot_legs" if corridor < 0.0 else StringName("dot_legs_%s" % corridor)
	var memo: Dictionary = astar.get_meta(key, {})

	if memo.is_empty() or int(memo.get(&"count", 0)) > DotNpcNavGraph.LEG_MEMO_MAX:
		memo = {&"count": 0}
		astar.set_meta(key, memo)

	return memo


static func leg_walkable(g: DotNpcNavGraph, memo: Variant, a: Vector3, b: Vector3, corridor: float) -> bool:
	if memo == null:
		return g.can_walk_straight(a, b, corridor)

	var row: Dictionary = memo.get(a, {})
	var known: Variant = row.get(b)

	if known != null:
		return known

	var walkable := g.can_walk_straight(a, b, corridor)

	if row.is_empty():
		memo[a] = row
	row[b] = walkable
	memo[&"count"] = int(memo[&"count"]) + 1
	return walkable
