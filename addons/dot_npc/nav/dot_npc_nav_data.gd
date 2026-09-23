@tool
class_name DotNpcNavData
extends Resource

## Where an NPC may stand, shipped beside the map it was generated from.
##
## [b]This is the navigation decision, and it is not a free one.[/b] Godot's own
## answer is [code]NavigationRegion3D[/code] baking a [code]NavigationMesh[/code] from
## source geometry at edit time. That is the right default for a game whose maps are
## authored in a scene — and this family's are not. Every map here is built in code
## from constants ([code]G2GGeometry[/code], [code]PlaygroundGeometry[/code],
## [code]ArenaMap[/code]), so at edit time there is no geometry to bake: the scene is
## an empty node with a script.
##
## So navigation follows dot-timer's zones exactly: generate it from [i]the same
## constants the geometry was built from[/i], with a [code]tools/export_nav.gd[/code]
## in the game, ship the result beside the map, and fail the suite when it was not
## re-run. A navmesh that has drifted from the geometry it was drawn against is an NPC
## walking through a wall, and it is invisible until somebody watches one do it.
##
## [b]That decision is what makes a delivered map able to have NPCs at all.[/b] A map
## arriving in a mounted dot-cloud pack cannot be baked on the client — there is no
## editor there — so the nav data has to be content, in the pack, like the zones.
##
## What comes out of that derivation is a graph of points rather than a polygon soup,
## because a code-built map knows its own connectivity — it built the floors — and
## deriving a graph from that is exact where re-deriving it from triangles is a guess.
## [DotNpcNavBuilder] generates it and [DotNpcNavGraph] searches it.
##
## [b]That is also why this is not a [code]NavigationMesh[/code].[/b] Godot's navigation
## wants polygons, and turning a point grid back into polygons in order to hand it to a
## server that would re-derive a graph from them is two lossy conversions to arrive
## where we started. A game with authored geometry should use
## [code]NavigationRegion3D[/code] and stock [code]NavigationAgent3D[/code]s instead,
## and nothing in dot-npc stops it: a [DotNpcSpawner] with no nav data spawns anywhere
## and a brain that owns an agent paths with that.

# No log channel: the document the exporter writes. validate() returns a DotResult and
# the spawner that adopts it logs the outcome with the map in hand.

## Bumped when the on-disk shape changes.
##
## 2 added per-point areas and flags and the cover list. A version 1 document still
## loads: the arrays are absent, every point is area 0 with no flags, and there is no
## cover — which is exactly what a graph generated before any of it existed described.
const FORMAT_VERSION := 2

## What a point is made of. An id, not a meaning: [DotNpcNavFilter] gives it a cost
## and a game decides what its own ids stand for.
##
## The four named here are the ones every map has had, and a generator is free to use
## any id up to [constant DotNpcNavFilter.MAX_AREAS].
const AREA_GROUND := 0
const AREA_WATER := 1
const AREA_HAZARD := 2
const AREA_DOOR := 3

## Per-point properties, as bits.
##
## The nav-mesh attributes twenty years of shipped practice settled on, minus the ones
## that belong to one round-based shooter. They are on the point rather than on the
## edge because a code-built map knows what a floor tile is; an edge between two of
## them inherits the worse of the two.
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

## What a cover spot is good for. Source's [code]HidingSpot[/code] flags.
enum Cover {
	IN_COVER = 1 << 0,   ## Hard cover close by, in the direction of the normal.
	SNIPER = 1 << 1,     ## A long sight line from here.
	EXPOSED = 1 << 2,    ## In the open. Recorded so it can be avoided, not used.
}

## The map this was generated for. Must match [code]DotMapDef.id[/code].
@export var map_id: StringName = &""

## A digest of the constants the geometry was built from.
##
## [b]The staleness check, and the whole reason this resource is safe to ship.[/b] The
## generator writes the digest of the map's own constants; a loader compares it with
## the digest of the constants it actually has. They differ exactly when somebody
## moved a wall and did not re-run the generator — which is the failure dot-timer's
## zones already have a suite check for, for the same reason.
@export var source_digest: String = ""

## Walkable points, in the map's world space.
@export var points: PackedVector3Array = PackedVector3Array()

## Undirected edges as index pairs into [member points]. Flat: [i0, j0, i1, j1, ...].
##
## A point graph rather than a polygon soup, because a code-built map knows its own
## connectivity — it built the floors — and deriving a graph from that is exact where
## re-deriving it from triangles is a guess.
@export var edges: PackedInt32Array = PackedInt32Array()

## How far off a point an NPC may still be considered on the mesh, in metres.
@export_range(0.1, 20.0, 0.1) var point_radius: float = 2.0

## The generator's grid step, in metres. 0 means "not recorded".
##
## [b]Written down rather than inferred, because two things need it and neither can
## guess.[/b] A straight-line walkability test has to sample at less than half a cell
## or it steps clean over one, and [member point_radius] is not that number: it is how
## far off the mesh an NPC may stand, which a generator is free to set to anything.
## Version 1 documents do not have it and fall back to [member point_radius], which is
## what every generator so far has set it to anyway.
@export_range(0.0, 20.0, 0.1) var grid_spacing: float = 0.0

## Area id per point, parallel to [member points]. Shorter than it is treated as all
## [constant AREA_GROUND].
##
## [b]Parallel arrays rather than an array of structures.[/b] A per-point Dictionary
## would be three allocations per point and this is content that ships with a map; a
## `PackedInt32Array` is four bytes. The cost is that they can fall out of step, which
## is why [method validate] checks the lengths and [method add_point] is the only
## thing that appends.
@export var areas: PackedInt32Array = PackedInt32Array()

## Flag bits per point, parallel to [member points]. See [enum Flag].
@export var flags: PackedInt32Array = PackedInt32Array()

## Places worth standing in a fight, in world space.
##
## Source keeps hiding spots as their own list rather than as an attribute of an area,
## because a spot is a point and an area is a rectangle — and the useful spot is the
## corner of the rectangle, not its middle. Same here: a cover spot is not a graph
## point, and an NPC going to one paths to the nearest graph point and then steps to
## the spot.
@export var cover_positions: PackedVector3Array = PackedVector3Array()

## For each cover spot, the direction the thing giving cover lies in.
##
## [b]This is what makes cover answerable without geometry.[/b] Nothing at runtime can
## raycast a map that was built from constants and shipped as a graph, so "am I in
## cover from that" cannot be computed then. The generator knows — it placed the
## obstacle — so it records which way the wall is, and the runtime question becomes a
## dot product.
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

	# Joined with a separator rather than concatenated. Without one, [1.0, 23.0] and
	# [12.0, 3.0] hash to different strings only by luck of the decimal point, and two
	# different maps sharing a digest is a stale navmesh that reports itself fresh —
	# the one failure this whole mechanism exists to catch.
	return "|".join(parts).sha256_text().substr(0, 16)


## The grid step, or the best guess available.
func spacing() -> float:
	return grid_spacing if grid_spacing > 0.0 else point_radius


func point_count() -> int:
	return points.size()


func edge_count() -> int:
	return edges.size() / 2


func add_point(p: Vector3, area: int = AREA_GROUND, point_flags: int = 0) -> int:
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
##
## For a generator that appended to [member points] directly, and for a version 1
## document being upgraded. Called by [method validate] rather than left to a caller,
## because a short array is not a document a caller can be expected to notice.
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
func nearest_point(p: Vector3, radius: float = -1.0) -> int:
	var limit := point_radius if radius < 0.0 else radius
	var limit_sq := limit * limit
	var best := -1
	var best_sq := INF

	for i in points.size():
		var d_sq := points[i].distance_squared_to(p)
		if d_sq < best_sq and d_sq <= limit_sq:
			best_sq = d_sq
			best = i

	return best


## Whether [param p] is close enough to the mesh for an NPC to stand there.
func is_navigable(p: Vector3, radius: float = -1.0) -> bool:
	return nearest_point(p, radius) >= 0


## The nearest navigable position to [param p], or [param p] when there is none.
func snap(p: Vector3, radius: float = -1.0) -> Vector3:
	var i := nearest_point(p, radius)
	return points[i] if i >= 0 else p


# --- Cover ------------------------------------------------------------------

func cover_count() -> int:
	return cover_positions.size()


## Records a place worth standing. [param normal] points at whatever gives the cover.
func add_cover(
	position: Vector3, normal: Vector3, spot_flags: int = Cover.IN_COVER
) -> int:
	cover_positions.append(position)
	# Normalised on the way in, because every query is a dot product against it and a
	# generator that passed a difference of two positions rather than a direction would
	# scale every comparison by the distance between them — which is not an error, just
	# a threshold that means something different per spot.
	cover_normals.append(normal.normalized() if normal.length_squared() > 0.0 else Vector3.FORWARD)
	cover_flags.append(spot_flags)
	return cover_positions.size() - 1


func cover_flags_of(index: int) -> int:
	if index < 0 or index >= cover_flags.size():
		return 0
	return cover_flags[index]


## The best place to stand near [param near] that is covered from [param threat].
##
## Returns the index, or -1. "Covered from" is the dot product between the spot's
## recorded normal and the direction to the threat: a spot whose wall is between it
## and the threat scores 1, one whose wall is behind it scores -1.
##
## [b]Scored rather than filtered.[/b] The nearest spot that is merely acceptable
## beats a perfect one across the map — an NPC that runs forty metres to the ideal
## corner has crossed the open ground it was trying to avoid.
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


# --- Staleness ---------------------------------------------------------------

## Whether [param current] still describes the geometry this was generated from.
##
## A game calls this from its suite with its own map constants; failing it means
## `tools/export_nav.gd` was not re-run.
func matches(current_digest: String) -> bool:
	return source_digest != "" and source_digest == current_digest


func validate() -> DotResult:
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

	# Longer than the point list is a generator bug and is refused; shorter is a
	# version 1 document, which is legitimate and is filled in. The asymmetry is the
	# point: absent means "not described yet", extra means "these describe points that
	# do not exist", and silently trimming the second would hide a real mistake.
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
