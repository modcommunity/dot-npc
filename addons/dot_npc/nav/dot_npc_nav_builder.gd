class_name DotNpcNavBuilder
extends RefCounted

## Turns a code-built map's own constants into [DotNpcNavData]. What a game's
## `tools/export_nav.gd` calls.
##
## [b]The generator lives in the addon and the constants live in the game.[/b] A map
## here is a script that builds boxes from numbers, so the only thing that knows where
## the floors are is that script — and the only honest navigation is one derived from
## the same numbers. This class is the derivation: a game hands it the walkable
## rectangles it drew its floors from, plus the obstacles it drew its walls from, and
## gets a point graph back.
##
## [codeblock]
## # game/tools/export_nav.gd
## var builder := DotNpcNavBuilder.new()
## builder.spacing = 2.0
## for floor_rect in PgLobby.FLOORS:
##     builder.add_floor(floor_rect.aabb, floor_rect.height)
## for wall in PgLobby.WALLS:
##     builder.add_obstacle(wall)
## var nav := builder.build(&"pg_lobby", DotNpcNavData.digest_of(PgLobby.CONSTANTS))
## ResourceSaver.save(nav, "res://maps/pg_lobby.nav.tres")
## [/codeblock]
##
## [b]The digest is the whole safety property.[/b] Nothing here can tell that a wall
## moved; what it can do is record a hash of the constants it was given, so a suite
## comparing that hash with the map's current constants fails the moment somebody moved
## a wall and did not re-run the tool. A navmesh that has drifted from its geometry is
## an NPC walking through a wall, and it is invisible until a person watches one do it.
##
## [b]A grid, not a Delaunay triangulation or a recast voxelisation.[/b] Both are
## better on authored geometry and both are the wrong trade here: the input is a
## handful of axis-aligned boxes and a grid over them is exact, is fifty lines, and is
## something a person reading the suite can check by hand. Recast exists for the case
## where the geometry is a mesh nobody described — which is not this case.

const CHANNEL := "npc.nav"

## Metres between graph points. Smaller is a better path and a slower search.
##
## [b]Two metres is the default because it is about a body width.[/b] Finer buys paths
## no player can tell apart and costs the A* quadratically; coarser starts cutting
## corners an NPC then walks into.
var spacing: float = 2.0

## How far from a point an NPC still counts as on the graph. Written into the data.
var point_radius: float = 2.0

## How far a point must be from an obstacle box to be kept, in metres.
##
## Half a body, so an NPC standing on the last legal point is not inside the wall. A
## radius of zero puts points against the geometry and every path scrapes it.
var clearance: float = 0.6

## Whether to record cover spots beside the obstacles.
##
## On, because it costs one pass over the points at generation time and a game that
## does not use cover simply never asks for it. The spots are content: a runtime that
## was handed a graph cannot raycast the map it came from, so if the generator does
## not write them down nothing can ever answer "where can I hide from that".
var generate_cover: bool = true

## How close a point must be to an obstacle to count as cover, in metres.
##
## One and a half body widths past the clearance. Closer and only points already
## scraping the wall qualify; further and the middle of a corridor is "cover", which
## makes an NPC take cover in the open and is worse than having no cover at all.
var cover_range: float = 1.6

## Walkable areas as {aabb, height, area_id, flags} — the floors the map built.
var _floors: Array = []

## Solid boxes that a point may not be inside of.
var _obstacles: Array[AABB] = []

## Extra links a generator wants that the grid cannot find: a ladder, a drop, a
## teleport. Pairs of world positions.
var _links: Array = []


## Adds a walkable rectangle. [param area] is used for its X and Z; Y comes from
## [param stand_height], which is where an NPC's feet go.
func add_floor(
	area: AABB,
	stand_height: float,
	area_id: int = DotNpcNavData.AREA_GROUND,
	point_flags: int = 0
) -> void:
	_floors.append({
		"area": area,
		"height": stand_height,
		"area_id": area_id,
		"flags": point_flags,
	})


## Adds a box nothing may stand inside.
func add_obstacle(box: AABB) -> void:
	_obstacles.append(box)


## Forces a connection between two places the grid would not join — a ladder, a drop.
##
## [b]Not optional in practice.[/b] The grid only connects neighbours on one floor, so
## a map with two storeys has two disconnected graphs and an NPC upstairs can never
## reach the ground. A stair built as a ramp is one floor and is fine; a stair built as
## steps is not, which is most of them here.
func add_link(from: Vector3, to: Vector3, link_flags: int = 0) -> void:
	_links.append([from, to, link_flags])


## Generates the data. [param digest] comes from [method DotNpcNavData.digest_of].
func build(map_id: StringName, digest: String) -> DotNpcNavData:
	var nav := DotNpcNavData.new()
	nav.map_id = map_id
	nav.source_digest = digest
	nav.point_radius = point_radius
	nav.grid_spacing = spacing

	# Point key -> index, where the key is the quantised position. Two floors that
	# overlap — a landing and the walkway it joins — would otherwise put two points in
	# the same spot, and an NPC standing between them oscillates.
	var seen := {}
	var positions: Array[Vector3] = []
	var point_areas: Array[int] = []
	var point_flags: Array[int] = []

	for entry in _floors:
		var floor_data: Dictionary = entry
		var area: AABB = floor_data["area"]
		var height := float(floor_data["height"])
		var floor_area_id := int(floor_data.get("area_id", DotNpcNavData.AREA_GROUND))
		var floor_flags := int(floor_data.get("flags", 0))

		var x := area.position.x + spacing * 0.5

		while x < area.position.x + area.size.x:
			var z := area.position.z + spacing * 0.5

			while z < area.position.z + area.size.z:
				var p := Vector3(x, height, z)
				z += spacing

				if _blocked(p):
					continue

				var key := _key(p)

				if seen.has(key):
					continue

				seen[key] = positions.size()
				positions.append(p)
				point_areas.append(floor_area_id)
				point_flags.append(floor_flags)

			x += spacing

	for i in positions.size():
		nav.add_point(positions[i], point_areas[i], point_flags[i])

	# Neighbours within one and a half spacings, so the four cardinals and the four
	# diagonals join and nothing further does. A plain `spacing` misses the diagonal
	# by a factor of root two and gives a graph an NPC walks around corners in right
	# angles on; twice the spacing joins across a one-cell gap, which is a point on
	# each side of a wall thin enough to have no point of its own inside it.
	var reach := spacing * 1.5
	var reach_sq := reach * reach

	for i in positions.size():
		for j in range(i + 1, positions.size()):
			if positions[i].distance_squared_to(positions[j]) > reach_sq:
				continue

			# A height difference greater than a step is not a neighbour. Without this
			# a walkway passing over a floor joins to it and an NPC paths through the
			# air — the single most common thing wrong with a generated graph.
			if absf(positions[i].y - positions[j].y) > spacing * 0.5:
				continue

			if _crosses_obstacle(positions[i], positions[j]):
				continue

			nav.connect_points(i, j)

	for link in _links:
		var pair: Array = link
		var a := nav.nearest_point(pair[0], spacing * 2.0)
		var b := nav.nearest_point(pair[1], spacing * 2.0)

		if a >= 0 and b >= 0 and a != b:
			nav.connect_points(a, b)

			# Flags are per point and a link is an edge, so the flags land on both
			# ends. Source does the same thing for the same reason — its JUMP
			# attribute is on the area, and "you had to jump to get here" is close
			# enough to "getting between these two is a jump" that no follower has
			# ever needed the difference.
			var link_flags := int(pair[2]) if pair.size() > 2 else 0
			if link_flags != 0:
				nav.add_flags(a, link_flags)
				nav.add_flags(b, link_flags)
		else:
			DotLog.warn(CHANNEL, "a navigation link found no point at one end", {
				"map": String(map_id),
				"from": str(pair[0]),
				"to": str(pair[1]),
			})

	if generate_cover:
		_mark_cover(nav)

	return nav


## Records a cover spot beside every point that has an obstacle close enough to hide
## behind, with the normal pointing at the obstacle.
##
## [b]One spot per point, not one per obstacle.[/b] A point in an inside corner has two
## walls and would otherwise produce two spots in the same place with different
## normals, which is not two places to hide — it is one place that is good against two
## directions, and the query picks whichever wall is nearest to the threat anyway.
##
## Only [constant DotNpcNavData.Cover.IN_COVER] is generated. Source also classifies
## sniper spots and exposed ledges, which needs long visibility traces over the whole
## map; a generator with the geometry in front of it can add those itself, and the
## flags exist so it can.
func _mark_cover(nav: DotNpcNavData) -> void:
	for i in nav.points.size():
		if (nav.flags_of(i) & DotNpcNavData.Flag.NO_HIDE) != 0:
			continue

		var p := nav.points[i]
		var best := Vector3.ZERO
		var best_distance := INF

		for box in _obstacles:
			# The nearest point on the box to this one, which decides both whether it
			# is close enough and which way the wall lies.
			var nearest := Vector3(
				clampf(p.x, box.position.x, box.position.x + box.size.x),
				clampf(p.y, box.position.y, box.position.y + box.size.y),
				clampf(p.z, box.position.z, box.position.z + box.size.z)
			)

			var to_box := nearest - p
			# Measured horizontally. The floor an NPC stands on is an obstacle
			# directly below it, and taking cover behind the ground is not a thing.
			to_box.y = 0.0

			var distance := to_box.length()
			if distance > cover_range or distance >= best_distance:
				continue

			if distance <= 0.0001:
				continue

			best_distance = distance
			best = to_box / distance

		if best_distance < INF:
			nav.add_cover(p, best, DotNpcNavData.Cover.IN_COVER)


func _key(p: Vector3) -> String:
	return "%d,%d,%d" % [
		roundi(p.x / spacing), roundi(p.y / spacing), roundi(p.z / spacing)
	]


func _blocked(p: Vector3) -> bool:
	for box in _obstacles:
		if box.grow(clearance).has_point(p):
			return true

	return false


## Whether the straight line between two points passes through an obstacle.
##
## Sampled rather than solved. An exact segment-versus-AABB test is not hard and is not
## what is wanted: what matters is that no sample sits inside, and the samples are a
## metre apart on a grid whose cells are two — so anything a body could not fit through
## is caught, and the cost is a handful of `has_point` calls at generation time only.
func _crosses_obstacle(a: Vector3, b: Vector3) -> bool:
	var steps := maxi(int(a.distance_to(b) / maxf(spacing * 0.5, 0.1)), 1)

	for i in range(1, steps):
		if _blocked(a.lerp(b, float(i) / float(steps))):
			return true

	return false


func describe() -> Dictionary:
	return {
		"floors": _floors.size(),
		"obstacles": _obstacles.size(),
		"links": _links.size(),
		"cover": generate_cover,
		"spacing": spacing,
	}
