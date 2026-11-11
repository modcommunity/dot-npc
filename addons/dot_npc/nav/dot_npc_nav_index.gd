class_name DotNpcNavIndex
extends RefCounted

## Spatial lookups [DotNpcNavBuilder] builds from: obstacle and cover buckets by cell, the already-placed
## test, and the piece (union-find) helpers. Static and stateless; the builder owns the dictionaries.

## Metres of (x, z) one obstacle bucket covers.
const OBSTACLE_CELL := 4.0


## Obstacle indexes by the (x, z) cells their grown box touches. Built on the first test
## after an obstacle is added: a map of two thousand boxes asked "is this point inside
## any of them" for every one of several thousand points was tens of millions of tests.
static func index_obstacles(obstacles: Array[AABB], clearance: float) -> Dictionary:
	var cells := {}

	for index in obstacles.size():
		var grown := obstacles[index].grow(clearance)

		for bx in range(floori(grown.position.x / OBSTACLE_CELL), floori(grown.end.x / OBSTACLE_CELL) + 1):
			for bz in range(floori(grown.position.z / OBSTACLE_CELL), floori(grown.end.z / OBSTACLE_CELL) + 1):
				var key := Vector2i(bx, bz)
				var bucket: PackedInt32Array = cells.get(key, PackedInt32Array())
				bucket.append(index)
				cells[key] = bucket

	return cells


## Obstacle indexes by the cells their footprint grown by [param cover_range] touches.
static func index_cover(obstacles: Array[AABB], cover_range: float) -> Dictionary:
	var cells := {}

	for index in obstacles.size():
		var box := obstacles[index]

		for bx in range(floori((box.position.x - cover_range) / OBSTACLE_CELL), floori((box.end.x + cover_range) / OBSTACLE_CELL) + 1):
			for bz in range(floori((box.position.z - cover_range) / OBSTACLE_CELL), floori((box.end.z + cover_range) / OBSTACLE_CELL) + 1):
				var key := Vector2i(bx, bz)
				var bucket: PackedInt32Array = cells.get(key, PackedInt32Array())
				bucket.append(index)
				cells[key] = bucket

	return cells


## Records a cover spot beside every point that has an obstacle close enough to hide behind, normal pointing at it.
## One spot per point, not per obstacle: an inside corner is one place good against two directions.
## Only IN_COVER is generated; sniper and ledge spots need whole-map traces a generator can add itself.
static func cover_at(nav: DotNpcNavData, cells: Dictionary, obstacles: Array[AABB], cover_range: float, i: int) -> Array:
	if (nav.flags_of(i) & DotNpcNavData.Flag.NO_HIDE) != 0:
		return [Vector3.ZERO, false]

	var p := nav.points[i]
	var best := Vector3.ZERO
	var best_distance := INF
	var bucket: Variant = cells.get(Vector2i(floori(p.x / OBSTACLE_CELL), floori(p.z / OBSTACLE_CELL)))

	if bucket == null:
		return [Vector3.ZERO, false]

	# Only the obstacles whose cover_range-grown footprint reaches this cell; the others are too
	# far to qualify, and the survivors are visited in obstacle order, so ties break as they did.
	for index: int in (bucket as PackedInt32Array):
		var box := obstacles[index]
		var nearest := Vector3(
			clampf(p.x, box.position.x, box.position.x + box.size.x),
			clampf(p.y, box.position.y, box.position.y + box.size.y),
			clampf(p.z, box.position.z, box.position.z + box.size.z)
		)

		var to_box := nearest - p
		# Measured horizontally. The floor an NPC stands on is an obstacle directly below it.
		to_box.y = 0.0

		var distance := to_box.length()
		if distance > cover_range or distance >= best_distance:
			continue

		if distance <= 0.0001:
			continue

		best_distance = distance
		best = to_box / distance

	return [best, best_distance < INF]


## Whether a point already placed is within [param within] of [param p], at the same height
## to within half a step.
static func already_placed(p: Vector3, seen: Dictionary, positions: Array[Vector3], spacing: float, within: float) -> bool:
	var cell := Vector2i(floori(p.x / spacing), floori(p.z / spacing))

	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var bucket: Variant = seen.get(cell + Vector2i(dx, dz))

			if bucket == null:
				continue

			for index: int in (bucket as PackedInt32Array):
				var other := positions[index]

				if absf(other.y - p.y) <= spacing * 0.5 and Vector2(other.x - p.x, other.z - p.z).length() < within:
					return true

	return false


## The union-find parents of [param count] points joined along the data's edges.
static func pieces(nav: DotNpcNavData, count: int) -> PackedInt32Array:
	var parent := PackedInt32Array()
	parent.resize(count)

	for i in parent.size():
		parent[i] = i

	var edges := nav.edges

	for k in range(0, edges.size(), 2):
		join_pieces(parent, edges[k], edges[k + 1])

	return parent


static func piece_of(parent: PackedInt32Array, i: int) -> int:
	while parent[i] != i:
		parent[i] = parent[parent[i]]
		i = parent[i]

	return i


static func join_pieces(parent: PackedInt32Array, a: int, b: int) -> void:
	var ra := piece_of(parent, a)
	var rb := piece_of(parent, b)

	if ra != rb:
		parent[rb] = ra
