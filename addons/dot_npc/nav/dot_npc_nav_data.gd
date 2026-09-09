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

const CHANNEL := "npc.nav"

const FORMAT_VERSION := 1

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


func point_count() -> int:
	return points.size()


func edge_count() -> int:
	return edges.size() / 2


func add_point(p: Vector3) -> int:
	points.append(p)
	return points.size() - 1


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

	return DotResult.success(null)


func to_dictionary() -> Dictionary:
	var flat := PackedFloat32Array()

	for p in points:
		flat.append(p.x)
		flat.append(p.y)
		flat.append(p.z)

	return {
		"format": FORMAT_VERSION,
		"map": String(map_id),
		"digest": source_digest,
		"radius": point_radius,
		"points": Array(flat),
		"edges": Array(edges),
		"meta": meta.duplicate(true),
	}


static func from_dictionary(data: Dictionary) -> DotNpcNavData:
	var nav := DotNpcNavData.new()

	nav.map_id = StringName(str(data.get("map", "")))
	nav.source_digest = str(data.get("digest", ""))
	nav.point_radius = maxf(float(data.get("radius", 2.0)), 0.1)

	var raw_points: Variant = data.get("points", [])

	if raw_points is Array:
		var arr := raw_points as Array
		var i := 0
		while i + 2 < arr.size():
			nav.points.append(Vector3(float(arr[i]), float(arr[i + 1]), float(arr[i + 2])))
			i += 3

	var raw_edges: Variant = data.get("edges", [])

	if raw_edges is Array:
		for e in (raw_edges as Array):
			nav.edges.append(int(e))

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
		"digest": source_digest,
	}


func _to_string() -> String:
	return "DotNpcNavData(%s, %d points)" % [String(map_id), points.size()]
