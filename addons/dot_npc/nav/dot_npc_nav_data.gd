@tool
class_name DotNpcNavData
extends Resource

## Where an NPC may stand, shipped beside the map it was generated from.
## A point graph generated from the map's own constants (`tools/export_nav.gd`), not a baked NavigationMesh:
## code-built maps have nothing to bake. A game with authored geometry should use NavigationRegion3D.

# No log channel: the document the exporter writes. validate() returns a DotResult and
# the spawner that adopts it logs the outcome with the map in hand.

## Bumped when the on-disk shape or what [DotNpcNavBuilder] builds from the same inputs changes
## (the digest hashes constants only, so an older builder's cache would pass as fresh). A stale cache is rebuilt.
## 2 added per-point areas, flags and cover (version 1 loads as area 0, no flags, no cover); 3 retired caches that dropped walkable edges.
const FORMAT_VERSION := 3

const CHANNEL := "npc.nav.data"

## What a point is made of. An id, not a meaning: [DotNpcNavFilter] gives it a cost
## and a game decides what its own ids stand for. A generator may use any id up to
## [constant DotNpcNavFilter.MAX_AREAS].
const AREA_GROUND := 0
const AREA_WATER := 1
const AREA_HAZARD := 2
const AREA_DOOR := 3

## Per-point properties, as bits.
## On the point, not the edge, because a code-built map knows what a floor tile is; an edge
## inherits the worse of its two points.
enum Flag {
	NONE = 0,
	CROUCH = 1 << 0,   ## Must crouch to be here.
	JUMP = 1 << 1,     ## Getting here is a jump, not a walk.
	AVOID = 1 << 2,    ## Passable and unpleasant. Costs more, never banned.
	STOP = 1 << 3,     ## Come to a halt on arriving — a ledge, a door.
	WALK = 1 << 4,     ## Do not run through here.
	DOOR = 1 << 5,     ## Something has to be opened.
	NO_HIDE = 1 << 6,  ## Never generate a cover spot here.
}

## What a cover spot is good for. The hiding-spot flags shipped navigation meshes use.
enum Cover {
	IN_COVER = 1 << 0,   ## Hard cover close by, in the direction of the normal.
	SNIPER = 1 << 1,     ## A long sight line from here.
	EXPOSED = 1 << 2,    ## In the open. Recorded so it can be avoided, not used.
}

## The map this was generated for. Must match [code]DotMapDef.id[/code].
@export var map_id: StringName = &""

## A digest of the constants the geometry was built from.
## The staleness check that makes shipping this safe: it differs exactly when a wall moved and
## the generator was not re-run.
@export var source_digest: String = ""

## Walkable points, in the map's world space.
@export var points: PackedVector3Array = PackedVector3Array()

## Undirected edges as index pairs into [member points]. Flat: [i0, j0, i1, j1, ...].
## A graph, not a polygon soup: a code-built map knows its own connectivity, so deriving it is exact.
@export var edges: PackedInt32Array = PackedInt32Array()

## How far off a point an NPC may still be considered on the mesh, in metres.
@export_range(0.1, 20.0, 0.1) var point_radius: float = 2.0

## The generator's grid step, in metres. 0 means "not recorded".
## Written down, not inferred: a walkability test must sample at under half a cell, and
## [member point_radius] is not that number. Version 1 documents fall back to it.
@export_range(0.0, 20.0, 0.1) var grid_spacing: float = 0.0

## Area id per point, parallel to [member points]. Shorter than it is treated as all [constant AREA_GROUND].
## Parallel arrays, not per-point Dictionaries: this ships with a map. They can fall out of step,
## so [method validate] checks lengths and [method add_point] is the only appender.
@export var areas: PackedInt32Array = PackedInt32Array()

## Flag bits per point, parallel to [member points]. See [enum Flag].
@export var flags: PackedInt32Array = PackedInt32Array()

## Places worth standing in a fight, in world space.
## A list apart from areas: a spot is a point and the useful one is a rectangle's corner. A cover
## spot is not a graph point; an NPC paths to the nearest graph point, then steps to it.
@export var cover_positions: PackedVector3Array = PackedVector3Array()

## For each cover spot, the direction the thing giving cover lies in.
## Makes cover answerable without geometry: nothing can raycast a map shipped as a graph, but the
## generator placed the obstacle, so the runtime question is a dot product.
@export var cover_normals: PackedVector3Array = PackedVector3Array()

## [enum Cover] bits per cover spot.
@export var cover_flags: PackedInt32Array = PackedInt32Array()

@export var meta: Dictionary = {}


## The digest a generator writes and a loader checks. Order-sensitive by design.
static func digest_of(constants: Array) -> String:
	var parts := PackedStringArray()

	for value in constants:
		# `var_to_str` rather than `str`, because `str` on a float drops precision and
		# a wall moved by a centimetre would then hash the same as one that was not.
		parts.append(var_to_str(value))

	# Joined with a separator: without one [1.0, 23.0] and [12.0, 3.0] can collide, and two maps
	# sharing a digest is a stale navmesh reporting itself fresh.
	return "|".join(parts).sha256_text().substr(0, 16)


## The grid step, or the best guess available.
func spacing() -> float:
	return grid_spacing if grid_spacing > 0.0 else point_radius


func point_count() -> int:
	return points.size()


func edge_count() -> int:
	return edges.size() / 2


func add_point(p: Vector3, area: int = AREA_GROUND, point_flags: int = 0) -> int:
	invalidate_index()
	points.append(p)
	areas.append(area)
	flags.append(point_flags)
	return points.size() - 1


## The area id of a point. [constant AREA_GROUND] for a point from a version 1
## document, and for an index that does not exist — a caller iterating a stale copy of
## the point list gets ordinary ground rather than an error.
func area_of(index: int) -> int:
	if index < 0 or index >= areas.size():
		return AREA_GROUND
	return areas[index]


func flags_of(index: int) -> int:
	if index < 0 or index >= flags.size():
		return 0
	return flags[index]


func set_area(index: int, area: int) -> void:
	if index >= 0 and index < areas.size():
		areas[index] = area


func set_flags(index: int, point_flags: int) -> void:
	if index >= 0 and index < flags.size():
		flags[index] = point_flags


func add_flags(index: int, point_flags: int) -> void:
	if index >= 0 and index < flags.size():
		flags[index] = flags[index] | point_flags


## Brings the parallel arrays up to the point count.
## For a generator that appended to [member points] directly and for upgrading version 1;
## [method validate] calls it because a short array is not something a caller will notice.
func normalise_arrays() -> void:
	while areas.size() < points.size():
		areas.append(AREA_GROUND)
	while flags.size() < points.size():
		flags.append(0)

	if areas.size() > points.size():
		areas.resize(points.size())
	if flags.size() > points.size():
		flags.resize(points.size())


func connect_points(a: int, b: int) -> DotResult:
	if a == b:
		return DotResult.fail(DotError.CODE_INVALID, "A point cannot connect to itself.")

	if a < 0 or b < 0 or a >= points.size() or b >= points.size():
		return DotResult.fail(
			DotError.CODE_INVALID, "Edge index out of range.", "%d-%d" % [a, b]
		)

	edges.append(a)
	edges.append(b)

	return DotResult.success(null)


## The nearest walkable point to [param p], or -1 when none is within [param radius].
## Through a bucket index, not a scan: every path request and walkability sample asks this. Ties
## go to the lowest index, so two machines never path differently depending on index layout.
func nearest_point(p: Vector3, radius: float = -1.0) -> int:
	return nearest_point_where(p, radius, Callable())


## [method nearest_point], skipping every point [param accept] says no to. [param accept]
## is `func(index: int) -> bool`; an invalid Callable accepts everything.
func nearest_point_where(p: Vector3, radius: float, accept: Callable) -> int:
	var limit := point_radius if radius < 0.0 else radius
	var limit_sq := limit * limit
	var best := -1
	var best_sq := INF

	_ensure_index()

	var cell := _bucket_size
	var x0 := floori((p.x - limit) / cell)
	var x1 := floori((p.x + limit) / cell)
	var z0 := floori((p.z - limit) / cell)
	var z1 := floori((p.z + limit) / cell)

	# A radius wider than the map would otherwise walk thousands of empty buckets; past
	# the point where buckets outnumber points, the scan is the cheaper question.
	if (x1 - x0 + 1) * (z1 - z0 + 1) > points.size():
		for i in points.size():
			var d_all := points[i].distance_squared_to(p)
			if d_all <= limit_sq and (d_all < best_sq or (d_all == best_sq and i < best)):
				if accept.is_valid() and not bool(accept.call(i)):
					continue
				best_sq = d_all
				best = i
		return best

	for bx in range(x0, x1 + 1):
		for bz in range(z0, z1 + 1):
			var bucket: Variant = _buckets.get(Vector2i(bx, bz))

			if bucket == null:
				continue

			for i: int in (bucket as PackedInt32Array):
				var d_sq := points[i].distance_squared_to(p)

				if d_sq > limit_sq or d_sq > best_sq or (d_sq == best_sq and i > best):
					continue

				if accept.is_valid() and not bool(accept.call(i)):
					continue

				best_sq = d_sq
				best = i

	return best


## Every point within [param radius] of [param p], by index, in no particular order.
func points_within(p: Vector3, radius: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	var limit_sq := radius * radius

	_ensure_index()

	var cell := _bucket_size

	for bx in range(floori((p.x - radius) / cell), floori((p.x + radius) / cell) + 1):
		for bz in range(floori((p.z - radius) / cell), floori((p.z + radius) / cell) + 1):
			var bucket: Variant = _buckets.get(Vector2i(bx, bz))

			if bucket == null:
				continue

			for i: int in (bucket as PackedInt32Array):
				if points[i].distance_squared_to(p) <= limit_sq:
					out.append(i)

	return out


## Builds the bucket index now if the points changed: queries from worker threads must find
## it built, because building it is a write.
func build_index() -> void:
	_ensure_index()


## Drops the bucket index, so the next query rebuilds it. For anything that edited
## [member points] in place: [method add_point] and [method validate] already do.
func invalidate_index() -> void:
	_buckets.clear()
	_indexed_count = -1


## Buckets of points by (x, z), two grid steps wide. Built on the first query after the
## points change, never stored with the document: it is derived from the points and a copy
## of it would be a second list that can fall out of step with the first.
var _buckets: Dictionary = {}
var _bucket_size: float = 4.0
var _indexed_count: int = -1


func _ensure_index() -> void:
	if _indexed_count == points.size() and (not _buckets.is_empty() or points.is_empty()):
		return

	_buckets.clear()
	_bucket_size = maxf(spacing() * 2.0, 1.0)

	for i in points.size():
		var key := Vector2i(floori(points[i].x / _bucket_size), floori(points[i].z / _bucket_size))
		var bucket: PackedInt32Array = _buckets.get(key, PackedInt32Array())
		bucket.append(i)
		# Written back: a PackedInt32Array out of a Dictionary is a copy.
		_buckets[key] = bucket

	_indexed_count = points.size()


## Whether [param p] is close enough to the mesh for an NPC to stand there.
func is_navigable(p: Vector3, radius: float = -1.0) -> bool:
	return nearest_point(p, radius) >= 0


## The nearest navigable position to [param p], or [param p] when there is none.
func snap(p: Vector3, radius: float = -1.0) -> Vector3:
	var i := nearest_point(p, radius)
	return points[i] if i >= 0 else p



func cover_count() -> int:
	return cover_positions.size()


## Records a place worth standing. [param normal] points at whatever gives the cover.
func add_cover(
	position: Vector3, normal: Vector3, spot_flags: int = Cover.IN_COVER
) -> int:
	cover_positions.append(position)
		# Normalised on the way in: every query is a dot product against it, and a non-unit normal
		# would scale every comparison by distance.
	cover_normals.append(normal.normalized() if normal.length_squared() > 0.0 else Vector3.FORWARD)
	cover_flags.append(spot_flags)
	return cover_positions.size() - 1


func cover_flags_of(index: int) -> int:
	if index < 0 or index >= cover_flags.size():
		return 0
	return cover_flags[index]


## The best place to stand near [param near] that is covered from [param threat].
## Returns the index, or -1. Covered is the dot product of the spot's normal and the direction to
## the threat (1 wall between, -1 wall behind). Scored, not filtered: the nearest acceptable spot beats a perfect one across open ground.
func best_cover(
	near: Vector3,
	threat: Vector3,
	max_distance: float = 20.0,
	wanted: int = Cover.IN_COVER,
	minimum_facing: float = 0.25
) -> int:
	var best := -1
	var best_score := -INF
	var max_sq := max_distance * max_distance

	for i in cover_positions.size():
		if wanted != 0 and (cover_flags[i] & wanted) == 0:
			continue

		var to_spot_sq := cover_positions[i].distance_squared_to(near)
		if to_spot_sq > max_sq:
			continue

		var to_threat := threat - cover_positions[i]
		if to_threat.length_squared() <= 0.0001:
			continue

		var facing := cover_normals[i].dot(to_threat.normalized())
		if facing < minimum_facing:
			continue

		# Distance in metres, facing in [-1, 1]. The weight is what decides between
		# "close" and "well covered", and eight metres per unit of facing is the point
		# at which walking further stops being worth better cover.
		var score := facing * 8.0 - sqrt(to_spot_sq)

		if score > best_score:
			best_score = score
			best = i

	return best


## The position of [method best_cover], or [param near] when there is none.
func cover_position_from(
	near: Vector3, threat: Vector3, max_distance: float = 20.0, wanted: int = Cover.IN_COVER
) -> Vector3:
	var index := best_cover(near, threat, max_distance, wanted)
	return cover_positions[index] if index >= 0 else near



## Whether [param current] still describes the geometry this was generated from.
## A game calls this from its suite; failing means `tools/export_nav.gd` was not re-run.
func matches(current_digest: String) -> bool:
	return source_digest != "" and source_digest == current_digest


func validate() -> DotResult:
	invalidate_index()

	if map_id == &"":
		return DotResult.fail(DotError.CODE_INVALID, "Nav data needs a map id.")

	if points.is_empty():
		return DotResult.fail(
			DotError.CODE_INVALID, "Nav data has no walkable points.", String(map_id)
		)

	if edges.size() % 2 != 0:
		return DotResult.fail(
			DotError.CODE_PARSE, "Edge list is not a whole number of pairs.",
			"%d" % edges.size()
		)

	for i in edges.size():
		if edges[i] < 0 or edges[i] >= points.size():
			return DotResult.fail(
				DotError.CODE_INVALID, "Edge index out of range.", "%d" % edges[i]
			)

	if source_digest == "":
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Nav data has no source digest, so nothing can tell whether it is stale.",
			String(map_id)
		)

		# Longer than the point list is a generator bug and is refused; shorter is a version 1
		# document and is filled in. Silently trimming the extra would hide a real mistake.
	if areas.size() > points.size() or flags.size() > points.size():
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Nav data has more area or flag entries than points.",
			"%d points, %d areas, %d flags" % [points.size(), areas.size(), flags.size()]
		)

	normalise_arrays()

	if cover_normals.size() != cover_positions.size() \
			or cover_flags.size() != cover_positions.size():
		return DotResult.fail(
			DotError.CODE_INVALID,
			"The cover lists are not the same length.",
			"%d positions, %d normals, %d flags" % [
				cover_positions.size(), cover_normals.size(), cover_flags.size()
			]
		)

	return DotResult.success(null)


func to_dictionary() -> Dictionary:
	var flat := PackedFloat32Array()

	for p in points:
		flat.append(p.x)
		flat.append(p.y)
		flat.append(p.z)

	var out := {
		"format": FORMAT_VERSION,
		"map": String(map_id),
		"digest": source_digest,
		"radius": point_radius,
		"spacing": grid_spacing,
		"points": Array(flat),
		"edges": Array(edges),
		"meta": meta.duplicate(true),
	}

	# Written only when they say something. A map of plain ground writes no areas and
	# no flags, which keeps a version 2 document byte-for-byte the size of a version 1
	# one for every map that has not used the feature.
	if _any_nonzero(areas):
		out["areas"] = Array(areas)
	if _any_nonzero(flags):
		out["flags"] = Array(flags)

	if not cover_positions.is_empty():
		var cover_flat := PackedFloat32Array()
		for p in cover_positions:
			cover_flat.append(p.x)
			cover_flat.append(p.y)
			cover_flat.append(p.z)

		var normal_flat := PackedFloat32Array()
		for n in cover_normals:
			normal_flat.append(n.x)
			normal_flat.append(n.y)
			normal_flat.append(n.z)

		out["cover"] = Array(cover_flat)
		out["cover_normals"] = Array(normal_flat)
		out["cover_flags"] = Array(cover_flags)

	return out


## The graph as compressed bytes, for [method from_cache_bytes]: packed arrays whole, no
## per-element conversion, so a graph of a hundred thousand edges saves and loads in tens of ms.
func to_cache_bytes() -> PackedByteArray:
	var raw := var_to_bytes({
		"format": FORMAT_VERSION, "map": String(map_id), "digest": source_digest,
		"radius": point_radius, "spacing": grid_spacing, "points": points, "edges": edges,
		"areas": areas, "flags": flags, "cover": cover_positions, "cover_normals": cover_normals,
		"cover_flags": cover_flags, "meta": meta,
	})
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, raw.size())
	out.append_array(raw.compress(FileAccess.COMPRESSION_GZIP))
	return out


## A graph from [method to_cache_bytes], or null when the bytes are not one (truncated,
## another format version): the caller builds it instead.
static func from_cache_bytes(bytes: PackedByteArray) -> DotNpcNavData:
	if bytes.size() < 8:
		return null
	# The raw size leads the bytes: decompress_dynamic fails on gzip in 4.7 and a bad size is no graph.
	var size := bytes.decode_u32(0)
	if size == 0 or size > 512 * 1024 * 1024:
		return null
	var raw := bytes.slice(4).decompress(size, FileAccess.COMPRESSION_GZIP)
	if raw.size() != size:
		return null
	var data: Variant = bytes_to_var(raw)
	if not data is Dictionary:
		return null
	var found := int((data as Dictionary).get("format", 0))
	if found != FORMAT_VERSION:
		DotLog.debug(CHANNEL, "nav cache rejected, will rebuild", {"format": found, "want": FORMAT_VERSION})
		return null
	var d := data as Dictionary
	var nav := DotNpcNavData.new()
	nav.map_id = StringName(str(d.get("map", "")))
	nav.source_digest = str(d.get("digest", ""))
	nav.point_radius = float(d.get("radius", 2.0))
	nav.grid_spacing = float(d.get("spacing", 0.0))
	nav.points = d.get("points", PackedVector3Array())
	nav.edges = d.get("edges", PackedInt32Array())
	nav.areas = d.get("areas", PackedInt32Array())
	nav.flags = d.get("flags", PackedInt32Array())
	nav.cover_positions = d.get("cover", PackedVector3Array())
	nav.cover_normals = d.get("cover_normals", PackedVector3Array())
	nav.cover_flags = d.get("cover_flags", PackedInt32Array())
	nav.meta = d.get("meta", {})
	nav.normalise_arrays()
	return nav


static func _any_nonzero(values: PackedInt32Array) -> bool:
	for value in values:
		if value != 0:
			return true
	return false


static func _read_vectors(raw: Variant) -> PackedVector3Array:
	var out := PackedVector3Array()

	if raw is Array:
		var arr := raw as Array
		var i := 0
		while i + 2 < arr.size():
			out.append(Vector3(float(arr[i]), float(arr[i + 1]), float(arr[i + 2])))
			i += 3

	return out


static func from_dictionary(data: Dictionary) -> DotNpcNavData:
	var nav := DotNpcNavData.new()

	nav.map_id = StringName(str(data.get("map", "")))
	nav.source_digest = str(data.get("digest", ""))
	nav.point_radius = maxf(float(data.get("radius", 2.0)), 0.1)
	nav.grid_spacing = maxf(float(data.get("spacing", 0.0)), 0.0)

	nav.points = _read_vectors(data.get("points", []))

	var raw_edges: Variant = data.get("edges", [])

	if raw_edges is Array:
		for e in (raw_edges as Array):
			nav.edges.append(int(e))

	var raw_areas: Variant = data.get("areas", [])
	if raw_areas is Array:
		for value in (raw_areas as Array):
			nav.areas.append(int(value))

	var raw_flags: Variant = data.get("flags", [])
	if raw_flags is Array:
		for value in (raw_flags as Array):
			nav.flags.append(int(value))

	# A version 1 document has neither, and a version 2 one of a plain map has neither
	# either. Both mean the same thing and both end up here.
	nav.normalise_arrays()

	nav.cover_positions = _read_vectors(data.get("cover", []))
	nav.cover_normals = _read_vectors(data.get("cover_normals", []))

	var raw_cover_flags: Variant = data.get("cover_flags", [])
	if raw_cover_flags is Array:
		for value in (raw_cover_flags as Array):
			nav.cover_flags.append(int(value))

	var meta_value: Variant = data.get("meta", {})
	nav.meta = (
		(meta_value as Dictionary).duplicate(true) if meta_value is Dictionary else {}
	)

	return nav


func describe() -> Dictionary:
	return {
		"map": String(map_id),
		"points": points.size(),
		"edges": edge_count(),
		"cover": cover_positions.size(),
		"digest": source_digest,
	}


func _to_string() -> String:
	return "DotNpcNavData(%s, %d points)" % [String(map_id), points.size()]
