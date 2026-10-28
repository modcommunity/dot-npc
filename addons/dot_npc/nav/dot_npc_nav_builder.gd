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

## How far, in spacings, two points may be and still join. 1.5 takes the grid's diagonal; 1.6 also
## joins the columns of two abutting floor rectangles whose grids sit half a step apart (1.58).
var neighbour_reach: float = 1.5

## How far below a point's height an obstacle's top may be and still block it, in metres; below
## that it is under the feet (a stair tread beside the flight's top step). Negative: the clearance.
var obstacle_under_feet: float = -1.0

## How far above a point an obstacle's underside may be and still block it, in metres: a body that tall does not
## fit in the gap (a desk top on legs). Negative: the clearance, which lets a body walk under anything 0.35 m up.
var obstacle_overhead: float = -1.0

## Metres within which two separate pieces of the graph are joined by their nearest pair of points, when
## that pair is within a step in height and nothing solid is between. Zero is off. For a floor plan whose
## rooms stop a metre short of each other (a threshold, a wall's thickness) and would be islands.
var bridge_gap: float = 0.0

## A floor no wider than half a spacing holds no grid point (the first sits half a spacing in); on
## puts one row or column at its middle, so a walkway cut into slivers is not a gap in the graph.
var centre_narrow_floors: bool = false

## How close a point must be to an obstacle to count as cover, in metres.
##
## One and a half body widths past the clearance. Closer and only points already
## scraping the wall qualify; further and the middle of a corridor is "cover", which
## makes an NPC take cover in the open and is worse than having no cover at all.
var cover_range: float = 1.6

## Walkable areas as {aabb, height, area_id, flags} — the floors the map built.
var _floors: Array = []

## Loose points on uneven ground: {points, slope, area_id, flags}.
var _point_sets: Array = []

## Solid boxes that a point may not be inside of.
var _obstacles: Array[AABB] = []

## Extra links a generator wants that the grid cannot find: a ladder, a drop, a
## teleport. Pairs of world positions.
var _links: Array = []

enum Phase { IDLE, FLOORS, SETS, POINTS, BUCKETS, EDGES, LINKS, COVER, DONE }

## Tasks the edge and cover passes are split across when [method step] is given no time budget.
## One is a plain serial pass. The result is the same for any count.
var workers: int = 1

## Whether the build writes its own warning about links it could not place. A caller that builds on a
## worker thread turns it off (the log is main-thread) and reads [method link_report] instead.
var log_summary := true

var _lock := Mutex.new()
var _cancelled := false
var _progress := 0.0
var _stage := "idle"
var _phase := Phase.IDLE
var _deadline := -1
var _nav: DotNpcNavData = null
var _map_id: StringName = &""
var _seen := {}
var _positions: Array[Vector3] = []
var _point_areas: Array[int] = []
var _point_flags: Array[int] = []
var _slopes := PackedFloat32Array()
var _near := {}
var _cover_normal := PackedVector3Array()
var _cover_has := PackedByteArray()
var _unlinked := 0
var _unlinked_examples: Array[String] = []
var _floor_index := 0
var _column := NAN
var _set_index := 0
var _set_cursor := 0
var _cursor := 0
var _edge_total := 0

## How many unplaceable links a build's one warning names.
const LINK_EXAMPLES := 3



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


## Adds points on uneven ground (a converted map's terrain). Two of them join where the rise
## is at most [param max_slope] per metre between them; a floor point keeps the floor's step.
func add_points(
	points: PackedVector3Array,
	max_slope: float,
	area_id: int = DotNpcNavData.AREA_GROUND,
	point_flags: int = 0
) -> void:
	_point_sets.append({"points": points, "slope": max_slope, "area_id": area_id, "flags": point_flags})


## Adds a box nothing may stand inside.
func add_obstacle(box: AABB) -> void:
	_obstacles.append(box)
	_obstacle_cells.clear()
	_cover_cells.clear()


## Forces a connection between two places the grid would not join — a ladder, a drop.
##
## [b]Not optional in practice.[/b] The grid only connects neighbours on one floor, so
## a map with two storeys has two disconnected graphs and an NPC upstairs can never
## reach the ground. A stair built as a ramp is one floor and is fine; a stair built as
## steps is not, which is most of them here.
##
## [param reach] above 0 widens the search for a point at each end from the default (twice the spacing) to that many metres,
## and takes only points within [param height_tolerance] of the end's height, for a ladder whose ends stand in a wall
## and a shaft rather than on the grid.
func add_link(from: Vector3, to: Vector3, link_flags: int = 0, reach: float = 0.0, height_tolerance: float = 1.5) -> void:
	_links.append([from, to, link_flags, reach, height_tolerance])


## Generates the data in one call, on this thread. [param digest] comes from [method DotNpcNavData.digest_of].
## For a build that must not stall a frame use [method begin] and [method step] (time-sliced on the
## main thread) or call [method step] with no budget from a worker thread.
func build(map_id: StringName, digest: String) -> DotNpcNavData:
	begin(map_id, digest)

	while not step(0.0) and not _cancelled:
		pass

	return result()


## Whether [method step] has finished the build begun by [method begin].
func is_done() -> bool:
	return _phase == Phase.DONE and not _cancelled


## The finished data; null until [method is_done].
func result() -> DotNpcNavData:
	return _nav if _phase == Phase.DONE and not _cancelled else null


## Whether [method cancel] was called since [method begin]; a cancelled build has no result.
func is_cancelled() -> bool:
	return _cancelled


## How far the build has got, 0 to 1, never going back. Safe to poll from any thread.
func progress() -> float:
	_lock.lock()
	var value := _progress
	_lock.unlock()
	return value


## The name of the pass the build is in ("points", "edges", "links", "cover", "done"). Safe from any thread.
func stage() -> String:
	_lock.lock()
	var value := _stage
	_lock.unlock()
	return value


## What the unplaceable links were: `map`, `links` (how many), `of` (how many were given) and `first` (a few examples).
## Empty when every link found its points. One line per build, because a converted map has hundreds.
func link_report() -> Dictionary:
	if _unlinked == 0:
		return {}
	return {"map": String(_map_id), "links": _unlinked, "of": _links.size(), "first": _unlinked_examples}


## Starts a build that [method step] then runs in pieces. Nothing is generated yet.
func begin(map_id: StringName, digest: String) -> void:
	_nav = DotNpcNavData.new()
	_nav.map_id = map_id
	_nav.source_digest = digest
	_nav.point_radius = point_radius
	_nav.grid_spacing = spacing
	_map_id = map_id
	_seen = {}
	_positions = []
	_point_areas = []
	_point_flags = []
	_slopes = PackedFloat32Array()
	_near = {}
	_cover_normal = PackedVector3Array()
	_cover_has = PackedByteArray()
	_cancelled = false
	_obstacle_cells.clear()
	_cover_cells.clear()
	_unlinked = 0
	_unlinked_examples = []
	_floor_index = 0
	_column = NAN
	_set_index = 0
	_set_cursor = 0
	_cursor = 0
	_edge_total = 0
	_progress = 0.0
	_phase = Phase.FLOORS
	_publish(0.0, "points")


## Runs the build for about [param budget_ms] milliseconds (0 = to the end) and returns whether it
## finished. Call it once a frame on the main thread, or once with no budget on a worker thread.
##
## [b]Pure arithmetic on the builder's own members, no physics or scene tree[/b], so it is safe to
## run off the main thread as long as nothing else touches this builder meanwhile. With [member workers]
## above one and no budget, the edge and cover passes are split across [WorkerThreadPool] tasks; the
## result is identical to the serial one (the pieces are merged in order).
func step(budget_ms: float = 0.0) -> bool:
	_deadline = Time.get_ticks_usec() + int(budget_ms * 1000.0) if budget_ms > 0.0 else -1

	while _phase != Phase.DONE:
		if _cancelled:
			return false

		if _timed_out():
			return false

		match _phase:
			Phase.FLOORS:
				_step_floors()
			Phase.SETS:
				_step_sets()
			Phase.POINTS:
				_step_points()
			Phase.BUCKETS:
				_step_buckets()
			Phase.EDGES:
				_step_edges()
			Phase.LINKS:
				_step_links()
			Phase.COVER:
				_step_cover()

	return true


func _timed_out() -> bool:
	return _cancelled or (_deadline >= 0 and Time.get_ticks_usec() >= _deadline)


## Asks a running [method step] to return at its next check; [method is_done] stays false. Safe from any thread.
func cancel() -> void:
	_cancelled = true


func _publish(fraction: float, stage_name: String) -> void:
	_lock.lock()
	_progress = maxf(_progress, minf(fraction, 1.0))
	_stage = stage_name
	_lock.unlock()


## Fractions of the whole each pass is worth, measured on a 22 000-point map: the edge pass is most of it.
const W_POINTS := 0.10
const W_EDGES := 0.65
const W_LINKS := 0.02
const W_COVER := 0.23

## Where a floor's first row or column of points goes along one axis.
func _first_sample(start: float, size: float) -> float:
	if centre_narrow_floors and size <= spacing * 0.5:
		return start + size * 0.5

	return start + spacing * 0.5


func _step_floors() -> void:
	# One grid column of one floor per call to the loop below, so a time slice can end between columns.
	while _floor_index < _floors.size():
		var floor_data: Dictionary = _floors[_floor_index]
		var area: AABB = floor_data["area"]
		var height := float(floor_data["height"])
		var floor_area_id := int(floor_data.get("area_id", DotNpcNavData.AREA_GROUND))
		var floor_flags := int(floor_data.get("flags", 0))

		if is_nan(_column):
			_column = _first_sample(area.position.x, area.size.x)

		while _column < area.position.x + area.size.x:
			var z := _first_sample(area.position.z, area.size.z)

			while z < area.position.z + area.size.z:
				var p := Vector3(_column, height, z)
				z += spacing

				if _blocked(p) or _already_placed(p, _seen, _positions, spacing * 0.5):
					continue

				_place(p, floor_area_id, floor_flags, 0.0)

			_column += spacing

			if _timed_out():
				_publish(W_POINTS * 0.5 * float(_floor_index) / float(maxi(_floors.size(), 1)), "points")
				return

		_floor_index += 1
		_column = NAN

	_phase = Phase.SETS
	_publish(W_POINTS * 0.5, "points")


func _step_sets() -> void:
	while _set_index < _point_sets.size():
		var set_data: Dictionary = _point_sets[_set_index]
		var pts: PackedVector3Array = set_data["points"]

		while _set_cursor < pts.size():
			var p := pts[_set_cursor]
			_set_cursor += 1

			if not (_blocked(p) or _already_placed(p, _seen, _positions, spacing * 0.5)):
				_place(p, int(set_data["area_id"]), int(set_data["flags"]), float(set_data["slope"]))

			if (_set_cursor & 255) == 0 and _timed_out():
				return

		_set_index += 1
		_set_cursor = 0

	_phase = Phase.POINTS
	_cursor = 0
	_publish(W_POINTS * 0.75, "points")


## Records a point at a place found free.
func _place(p: Vector3, area_id: int, point_flags: int, slope: float) -> void:
	var cell := Vector2i(floori(p.x / spacing), floori(p.z / spacing))
	var bucket: PackedInt32Array = _seen.get(cell, PackedInt32Array())
	bucket.append(_positions.size())
	_seen[cell] = bucket
	_positions.append(p)
	_point_areas.append(area_id)
	_point_flags.append(point_flags)
	_slopes.append(slope)


func _step_points() -> void:
	while _cursor < _positions.size():
		_nav.add_point(_positions[_cursor], _point_areas[_cursor], _point_flags[_cursor])
		_cursor += 1

		if (_cursor & 1023) == 0 and _timed_out():
			return

	_phase = Phase.BUCKETS
	_cursor = 0


## Bucketed by (x, z), so each point is compared with the points near it rather than with every
## other point. A bucket is `reach` wide, so every possible neighbour is in the three-by-three block
## round a point's own.
func _step_buckets() -> void:
	var reach := spacing * neighbour_reach

	while _cursor < _positions.size():
		var key := Vector2i(floori(_positions[_cursor].x / reach), floori(_positions[_cursor].z / reach))
		var bucket: PackedInt32Array = _near.get(key, PackedInt32Array())
		bucket.append(_cursor)
		_near[key] = bucket
		_cursor += 1

		if (_cursor & 1023) == 0 and _timed_out():
			return

	if _obstacle_cells.is_empty() and not _obstacles.is_empty():
		_index_obstacles()

	_phase = Phase.EDGES
	_cursor = 0
	_edge_total = _positions.size()
	_publish(W_POINTS, "edges")


const EDGE_BATCH := 64

func _step_edges() -> void:
	if _edge_total == 0:
		_phase = Phase.LINKS
		return

	if workers > 1 and _deadline < 0 and _edge_total >= EDGE_BATCH * 4:
		_run_parallel(_edge_chunk, W_POINTS, W_EDGES, "edges")

		if _cancelled:
			return

		for parts: Variant in _chunks:
			for part: Variant in (parts as Array):
				var pairs: PackedInt32Array = part

				for k in range(0, pairs.size(), 2):
					_nav.connect_points(pairs[k], pairs[k + 1])

		_phase = Phase.LINKS
		_cursor = 0
		_publish(W_POINTS + W_EDGES, "links")
		return

	while _cursor < _edge_total:
		var last := mini(_cursor + EDGE_BATCH, _edge_total)
		var pairs := _edges_between(_cursor, last)

		for k in range(0, pairs.size(), 2):
			_nav.connect_points(pairs[k], pairs[k + 1])

		_cursor = last
		_publish(W_POINTS + W_EDGES * float(_cursor) / float(_edge_total), "edges")

		if _timed_out():
			return

	_phase = Phase.LINKS
	_cursor = 0
	_publish(W_POINTS + W_EDGES, "links")


## The edges (pairs of indexes, lower first) from the points [param from] up to [param to], in the
## order the all-pairs loop gave them.
func _edges_between(from: int, to: int) -> PackedInt32Array:
	var reach := spacing * neighbour_reach
	var reach_sq := reach * reach
	var out := PackedInt32Array()

	for i in range(from, to):
		var home := Vector2i(floori(_positions[i].x / reach), floori(_positions[i].z / reach))
		var found := PackedInt32Array()

		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var bucket: Variant = _near.get(home + Vector2i(dx, dz))
				if bucket != null:
					for j: int in (bucket as PackedInt32Array):
						if j > i:
							found.append(j)

		found.sort()

		for j in found:
			if _positions[i].distance_squared_to(_positions[j]) > reach_sq:
				continue

			# A height difference greater than a step is not a neighbour. Without this a walkway
			# passing over a floor joins to it and an NPC paths through the air.
			if absf(_positions[i].y - _positions[j].y) > _rise(_positions[i], _positions[j], _slopes[i], _slopes[j]):
				continue

			if _crosses_obstacle(_positions[i], _positions[j]):
				continue

			out.append(i)
			out.append(j)

	return out


func _edge_chunk(from: int, to: int) -> Variant:
	return _edges_between(from, to)


func _cover_chunk(from: int, to: int) -> Variant:
	var normals := PackedVector3Array()
	var has := PackedByteArray()

	for i in range(from, to):
		var found := _cover_at(i)
		normals.append(found[0])
		has.append(1 if found[1] else 0)

	return [normals, has]


## Splits the points into [member workers] ranges of whole batches, runs [param work] on each as a
## [WorkerThreadPool] group task, waits, and leaves the results in [member _chunks] in range order.
func _run_parallel(work: Callable, base: float, weight: float, stage_name: String) -> void:
	var total := _positions.size()
	var count := clampi(workers, 1, 32)
	var per := int(ceil(float(total) / float(count) / float(EDGE_BATCH))) * EDGE_BATCH
	_chunks = []
	_chunks.resize(count)
	_chunk_work = work
	_chunk_per = per
	_chunk_base = base
	_chunk_weight = weight
	_chunk_stage = stage_name
	_chunk_done = 0
	_chunk_total = total
	var group := WorkerThreadPool.add_group_task(_run_chunk, count, count, true, "dot_npc nav " + stage_name)
	WorkerThreadPool.wait_for_group_task_completion(group)


var _chunk_work: Callable
var _chunk_per := 0
var _chunk_base := 0.0
var _chunk_weight := 0.0
var _chunk_stage := ""
var _chunk_done := 0
var _chunk_total := 0
var _chunks: Array = []

func _run_chunk(index: int) -> void:
	var from := index * _chunk_per
	var to := mini(from + _chunk_per, _chunk_total)
	var parts: Array = []

	var at := from
	while at < to and not _cancelled:
		var last := mini(at + EDGE_BATCH, to)
		parts.append(_chunk_work.call(at, last))
		_lock.lock()
		_chunk_done += last - at
		var fraction := _chunk_base + _chunk_weight * float(_chunk_done) / float(maxi(_chunk_total, 1))
		_progress = maxf(_progress, minf(fraction, 1.0))
		_stage = _chunk_stage
		_lock.unlock()
		at = last

	_lock.lock()
	_chunks[index] = parts
	_lock.unlock()


func _link_end(pair: Array, end: int) -> int:
	var reach: float = pair[3] if pair.size() > 3 else 0.0

	if reach <= 0.0:
		return _nav.nearest_point(pair[end], spacing * 2.0)

	var at: Vector3 = pair[end]
	var tolerance: float = pair[4]
	return _nav.nearest_point_where(at, reach, func(p: int) -> bool: return absf(_nav.points[p].y - at.y) <= tolerance)


func _step_links() -> void:
	while _cursor < _links.size():
		var pair: Array = _links[_cursor]
		_cursor += 1
		var a := _link_end(pair, 0)
		var b := _link_end(pair, 1)

		if a >= 0 and b >= 0 and a != b:
			_nav.connect_points(a, b)

			# Flags are per point and a link is an edge, so the flags land on both ends.
			var link_flags := int(pair[2]) if pair.size() > 2 else 0
			if link_flags != 0:
				_nav.add_flags(a, link_flags)
				_nav.add_flags(b, link_flags)
		else:
			_unlinked += 1
			if _unlinked_examples.size() < LINK_EXAMPLES:
				_unlinked_examples.append("%s -> %s" % [pair[0], pair[1]])

		if (_cursor & 63) == 0 and _timed_out():
			return

	if _unlinked > 0 and log_summary:
		var report := link_report()
		DotLog.warn(CHANNEL, "navigation links found no point at one end", report)

	if bridge_gap > 0.0:
		_bridge_pieces()

	_cursor = 0
	_phase = Phase.COVER if generate_cover else Phase.DONE
	_publish(W_POINTS + W_EDGES + W_LINKS, "cover" if generate_cover else "done")

	if _phase == Phase.DONE:
		_finish()


## Joins the nearest pairs of points across pieces, shortest first, one join for each pair of pieces.
func _bridge_pieces() -> void:
	var parent := PackedInt32Array()
	parent.resize(_positions.size())

	for i in parent.size():
		parent[i] = i

	var edges := _nav.edges

	for k in range(0, edges.size(), 2):
		_join_pieces(parent, edges[k], edges[k + 1])

	var found: Array[Vector3] = []

	for i in _positions.size():
		for j in _nav.points_within(_positions[i], bridge_gap):
			if j <= i or _piece_of(parent, i) == _piece_of(parent, j):
				continue

			if absf(_positions[i].y - _positions[j].y) > _rise(_positions[i], _positions[j], _slopes[i], _slopes[j]):
				continue

			if not _crosses_obstacle(_positions[i], _positions[j]):
				found.append(Vector3(_positions[i].distance_to(_positions[j]), i, j))

	found.sort_custom(func(a: Vector3, b: Vector3) -> bool: return a.x < b.x or (a.x == b.x and (a.y < b.y or (a.y == b.y and a.z < b.z))))
	var bridged := 0

	for pair in found:
		if _piece_of(parent, int(pair.y)) != _piece_of(parent, int(pair.z)):
			_nav.connect_points(int(pair.y), int(pair.z))
			_join_pieces(parent, int(pair.y), int(pair.z))
			bridged += 1

	if bridged > 0 and log_summary:
		DotLog.debug(CHANNEL, "navigation pieces bridged", {"bridges": bridged, "gap": bridge_gap})


static func _piece_of(parent: PackedInt32Array, i: int) -> int:
	while parent[i] != i:
		parent[i] = parent[parent[i]]
		i = parent[i]

	return i


static func _join_pieces(parent: PackedInt32Array, a: int, b: int) -> void:
	var ra := _piece_of(parent, a)
	var rb := _piece_of(parent, b)

	if ra != rb:
		parent[rb] = ra


func _step_cover() -> void:
	var total := _nav.points.size()

	if total == 0:
		_finish()
		return

	if _cover_cells.is_empty() and not _obstacles.is_empty():
		_index_cover()

	if workers > 1 and _deadline < 0 and total >= EDGE_BATCH * 4:
		_run_parallel(_cover_chunk, W_POINTS + W_EDGES + W_LINKS, W_COVER, "cover")

		if _cancelled:
			return

		for parts: Variant in _chunks:
			for part: Variant in (parts as Array):
				var normals: PackedVector3Array = part[0]
				var has: PackedByteArray = part[1]
				_cover_normal.append_array(normals)
				_cover_has.append_array(has)

		_apply_cover()
		_finish()
		return

	while _cursor < total:
		var last := mini(_cursor + EDGE_BATCH, total)

		for i in range(_cursor, last):
			var found := _cover_at(i)
			_cover_normal.append(found[0])
			_cover_has.append(1 if found[1] else 0)

		_cursor = last
		_publish(W_POINTS + W_EDGES + W_LINKS + W_COVER * float(_cursor) / float(total), "cover")

		if _timed_out():
			return

	_apply_cover()
	_finish()


func _apply_cover() -> void:
	for i in _cover_has.size():
		if _cover_has[i] != 0:
			_nav.add_cover(_nav.points[i], _cover_normal[i], DotNpcNavData.Cover.IN_COVER)


func _finish() -> void:
	_phase = Phase.DONE
	_publish(1.0, "done")


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
func _cover_at(i: int) -> Array:
	if (_nav.flags_of(i) & DotNpcNavData.Flag.NO_HIDE) != 0:
		return [Vector3.ZERO, false]

	var p := _nav.points[i]
	var best := Vector3.ZERO
	var best_distance := INF
	var bucket: Variant = _cover_cells.get(Vector2i(floori(p.x / OBSTACLE_CELL), floori(p.z / OBSTACLE_CELL)))

	if bucket == null:
		return [Vector3.ZERO, false]

	# Only the obstacles whose cover_range-grown footprint reaches this cell; the others are too
	# far to qualify, and the survivors are visited in obstacle order, so ties break as they did.
	for index: int in (bucket as PackedInt32Array):
		var box := _obstacles[index]
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


## Obstacle indexes by the cells their footprint grown by [member cover_range] touches.
func _index_cover() -> void:
	_cover_cells.clear()

	for index in _obstacles.size():
		var box := _obstacles[index]

		for bx in range(floori((box.position.x - cover_range) / OBSTACLE_CELL), floori((box.end.x + cover_range) / OBSTACLE_CELL) + 1):
			for bz in range(floori((box.position.z - cover_range) / OBSTACLE_CELL), floori((box.end.z + cover_range) / OBSTACLE_CELL) + 1):
				var key := Vector2i(bx, bz)
				var bucket: PackedInt32Array = _cover_cells.get(key, PackedInt32Array())
				bucket.append(index)
				_cover_cells[key] = bucket


var _cover_cells: Dictionary = {}


## The most two neighbours may differ in height: a step on a floor, the slope on uneven ground.
func _rise(a: Vector3, b: Vector3, slope_a: float, slope_b: float) -> float:
	if slope_a <= 0.0 or slope_b <= 0.0:
		return spacing * 0.5
	return minf(slope_a, slope_b) * Vector2(a.x - b.x, a.z - b.z).length()


## Whether a point already placed is within [param within] of [param p], at the same height
## to within half a step.
func _already_placed(p: Vector3, seen: Dictionary, positions: Array[Vector3], within: float) -> bool:
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


func _overhead() -> float:
	return clearance if obstacle_overhead < 0.0 else obstacle_overhead


func _under_feet() -> float:
	return clearance if obstacle_under_feet < 0.0 else obstacle_under_feet


func _blocked(p: Vector3) -> bool:
	if _obstacle_cells.is_empty() and not _obstacles.is_empty():
		_index_obstacles()

	var bucket: Variant = _obstacle_cells.get(
		Vector2i(floori(p.x / OBSTACLE_CELL), floori(p.z / OBSTACLE_CELL))
	)

	if bucket == null:
		return false

	for index: int in (bucket as PackedInt32Array):
		var box: AABB = _obstacles[index]

		if box.end.y < p.y - _under_feet() or box.end.y + clearance < p.y or box.position.y > p.y + _overhead():
			continue

		var wide := box.grow(clearance)

		if p.x >= wide.position.x and p.x <= wide.end.x and p.z >= wide.position.z and p.z <= wide.end.z:
			return true

	return false


## Metres of (x, z) one obstacle bucket covers.
const OBSTACLE_CELL := 4.0

## Obstacle indexes by the (x, z) cells their grown box touches. Built on the first test
## after an obstacle is added: a map of two thousand boxes asked "is this point inside
## any of them" for every one of several thousand points was tens of millions of tests.
var _obstacle_cells: Dictionary = {}


func _index_obstacles() -> void:
	_obstacle_cells.clear()

	for index in _obstacles.size():
		var grown := _obstacles[index].grow(clearance)

		for bx in range(floori(grown.position.x / OBSTACLE_CELL), floori(grown.end.x / OBSTACLE_CELL) + 1):
			for bz in range(floori(grown.position.z / OBSTACLE_CELL), floori(grown.end.z / OBSTACLE_CELL) + 1):
				var key := Vector2i(bx, bz)
				var bucket: PackedInt32Array = _obstacle_cells.get(key, PackedInt32Array())
				bucket.append(index)
				_obstacle_cells[key] = bucket


## Whether the straight line between two points passes through an obstacle.
##
## Sampled rather than solved. An exact segment-versus-AABB test is not hard and is not
## what is wanted: what matters is that no sample sits inside, and the samples are a
## metre apart on a grid whose cells are two — so anything a body could not fit through
## is caught, and the cost is a handful of `has_point` calls at generation time only.
func _crosses_obstacle(a: Vector3, b: Vector3) -> bool:
	# At least two steps: a shorter-than-a-cell edge was floor-divided to one step and never sampled, so a diagonal clipping a door frame's corner was kept.
	var steps := maxi(ceili(a.distance_to(b) / maxf(spacing * 0.5, 0.1)), 2)

	for i in range(1, steps):
		if _blocked(a.lerp(b, float(i) / float(steps))):
			return true

	return false


func describe() -> Dictionary:
	return {
		"floors": _floors.size(),
		"point_sets": _point_sets.size(),
		"obstacles": _obstacles.size(),
		"links": _links.size(),
		"cover": generate_cover,
		"spacing": spacing,
	}
