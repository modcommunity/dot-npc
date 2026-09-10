class_name DotNpcNavFilter
extends RefCounted

## Which parts of the graph one NPC may use, and what they cost it.
##
## Detour's [code]dtQueryFilter[/code], in the shape a point graph needs. Two ideas,
## both of which a navmesh needs and a plain A* does not have:
##
## [b]Areas cost different amounts.[/b] A path across water, through fire or over a
## catwalk is passable and undesirable, and the only way to say "go round unless going
## round is much worse" is to make the crossing cost more. A hard ban cannot express
## it: an NPC that will never step in water is one that stands at the edge of a puddle
## for ever when the puddle is the only way through.
##
## [b]Flags decide what is passable at all.[/b] A crouching corridor is impassable to
## something that cannot crouch; a door is impassable to something that cannot open
## one. That is per-NPC, not per-map, so it belongs on the query rather than in the
## data.
##
## [codeblock]
## var filter := DotNpcNavFilter.new()
## filter.set_area_cost(DotNpcNavData.AREA_WATER, 6.0)   # wade only if you must
## filter.exclude_flags = DotNpcNavData.Flag.CROUCH      # this one cannot crouch
## graph.filter = filter
## [/codeblock]
##
## [b]A filter is a property of the asker, not of the graph.[/b] One graph serves
## every NPC on the map and they do not agree about it — which is why this is a
## separate object a caller hands in, rather than fields on [DotNpcNavData].

const CHANNEL := "npc.nav"

## Areas an id may take. Detour uses 64; sixteen is more than a code-built map has
## ever needed and keeps the cost table a cache line.
const MAX_AREAS := 16

## Cost multiplier per area id. 1.0 is ordinary ground.
var area_costs: PackedFloat32Array = PackedFloat32Array()

## A point must carry at least one of these flags, unless this is 0.
##
## Zero means "no requirement", not "nothing passes". The opposite reading is the
## trap: a filter constructed and never configured would then refuse the whole map,
## and the symptom is an NPC that never moves with nothing erroring.
var include_flags: int = 0

## A point carrying any of these flags is impassable.
var exclude_flags: int = 0

## Cost multiplier applied to any point flagged [constant DotNpcNavData.Flag.AVOID].
##
## Separate from the area table because AVOID is a property of the [i]place[/i] rather
## than of what it is made of — Source marks it on a nav area — and a game should be
## able to say "avoid this ledge" without spending an area id on it.
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
##
## [b]Worth having and easy to get wrong.[/b] The check is not "was anything set" but
## "is anything different from the default", because a caller that set an area cost
## back to 1.0 has a filter that costs a dictionary lookup per edge and changes
## nothing.
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
