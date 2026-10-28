class_name DotNpcNavFilter
extends RefCounted

## Which parts of the graph one NPC may use, and what they cost it. Detour's `dtQueryFilter` for a point graph.
## Areas cost different amounts (a hard ban strands an NPC at a puddle that is the only way through);
## flags decide what is passable at all. A property of the asker, so an object a caller hands in, not fields on [DotNpcNavData].

# No log channel: a value object of costs and flags. It cannot fail against anything.

## Areas an id may take. Detour uses 64; sixteen is more than a code-built map has
## ever needed and keeps the cost table a cache line.
const MAX_AREAS := 16

## Cost multiplier per area id. 1.0 is ordinary ground.
var area_costs: PackedFloat32Array = PackedFloat32Array()

## A point must carry at least one of these flags, unless this is 0.
## Zero means "no requirement", not "nothing passes": the opposite would make a never-configured filter refuse the whole map.
var include_flags: int = 0

## A point carrying any of these flags is impassable.
var exclude_flags: int = 0

## Cost multiplier applied to any point flagged [constant DotNpcNavData.Flag.AVOID].
## Separate from the area table: AVOID is a property of the place, and needs no area id.
var avoid_cost: float = 4.0


func _init() -> void:
	area_costs.resize(MAX_AREAS)
	area_costs.fill(1.0)


## The cost multiplier for one area id. Out-of-range ids cost 1.0 rather than
## erroring: an id from data a newer generator wrote is not a reason to refuse to path.
func area_cost(area: int) -> float:
	if area < 0 or area >= MAX_AREAS:
		return 1.0
	return area_costs[area]


func set_area_cost(area: int, cost: float) -> DotResult:
	if area < 0 or area >= MAX_AREAS:
		return DotResult.fail(
			DotError.CODE_INVALID, "Area id out of range.", "%d" % area
		)

	if cost <= 0.0:
		# A zero or negative cost makes A* explore for ever, or worse, prefer a cycle.
		# "Free" is not a thing a movement cost can be.
		return DotResult.fail(
			DotError.CODE_INVALID, "An area cost must be positive.", "%f" % cost
		)

	area_costs[area] = cost
	return DotResult.success(cost)


## Whether a point may be stepped on at all.
func passes(area: int, flags: int) -> bool:
	if exclude_flags != 0 and (flags & exclude_flags) != 0:
		return false

	if include_flags != 0 and (flags & include_flags) == 0:
		return false

	return area_cost(area) > 0.0


## What one metre through this point costs.
func cost_multiplier(area: int, flags: int) -> float:
	var cost := area_cost(area)

	if (flags & DotNpcNavData.Flag.AVOID) != 0:
		cost *= avoid_cost

	return cost


## Whether this filter would change any answer. Lets the graph skip the whole lookup.
## Tests for "different from the default", not "was set": an area cost set back to 1.0 changes nothing.
func is_neutral() -> bool:
	if include_flags != 0 or exclude_flags != 0:
		return false

	if not is_equal_approx(avoid_cost, 1.0):
		# AVOID is only interesting when some point carries it, which the graph knows
		# and this does not. Reported as not neutral, which costs a multiply per edge
		# on a map with no avoid flags and is the safe way round.
		return false

	for cost in area_costs:
		if not is_equal_approx(cost, 1.0):
			return false

	return true


## A filter that changes nothing. What a graph uses when none was given.
static func neutral() -> DotNpcNavFilter:
	var out := DotNpcNavFilter.new()
	out.avoid_cost = 1.0
	return out


## The common case: ordinary ground, and stay off anything marked AVOID unless the
## detour is more than four times as long.
static func cautious() -> DotNpcNavFilter:
	return DotNpcNavFilter.new()


## For something that cannot crouch, jump or open a door.
static func walking_only() -> DotNpcNavFilter:
	var out := DotNpcNavFilter.new()
	out.exclude_flags = (
		DotNpcNavData.Flag.CROUCH | DotNpcNavData.Flag.JUMP | DotNpcNavData.Flag.DOOR
	)
	return out


func duplicate_filter() -> DotNpcNavFilter:
	var out := DotNpcNavFilter.new()
	out.area_costs = area_costs.duplicate()
	out.include_flags = include_flags
	out.exclude_flags = exclude_flags
	out.avoid_cost = avoid_cost
	return out


func describe() -> Dictionary:
	var costs: Dictionary = {}
	for i in MAX_AREAS:
		if not is_equal_approx(area_costs[i], 1.0):
			costs[i] = area_costs[i]

	return {
		"include": include_flags,
		"exclude": exclude_flags,
		"avoid_cost": avoid_cost,
		"area_costs": costs,
		"neutral": is_neutral(),
	}


func _to_string() -> String:
	return "DotNpcNavFilter(%s)" % describe()
