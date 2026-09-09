@tool
class_name DotNpcLimits
extends DotConfig

## How many NPCs may exist, how fast they may arrive, and how hard they may think.
##
## [b]Population is the whole cost of an NPC layer.[/b] dot-props learned this with
## crates: the failure is not malice, it is a director that spawns four a second while
## nobody kills any, and a physics-and-pathfinding step that goes from two
## milliseconds to two hundred. Every number here exists because a server without it
## has the same evening.
##
## A [DotConfig], so an operator retunes a horde in a file or on the command line
## without a rebuild — which is what actually happens the evening a server falls over.

@export_group("Population")

## Most NPCs in the world at once, counted in [member DotNpcDef.cost]. 0 = unlimited.
@export_range(0, 10000, 1) var world_budget: int = 96

## Most of any one kind at once. 0 = unlimited.
##
## [b]Not the same limit as the budget, and it is the one that saves a round.[/b] A
## budget alone lets a director spend the whole thing on the one kind that happens to
## be cheapest, which is how a horde game ends up as ninety identical crawlers.
@export_range(0, 1000, 1) var per_kind_cap: int = 24

## Seconds between spawns from one spawner. 0 = no wait.
##
## The one that stops a runaway director: a budget alone does not, because a director
## that kills one and spawns one can churn as fast as the tick.
@export_range(0.0, 10.0, 0.01) var spawn_interval: float = 0.1

## Most NPCs one call to [method DotNpcSpawner.spawn_group] may create.
@export_range(1, 200, 1) var burst_cap: int = 12

@export_group("Lifetime")

## Metres beyond which an NPC with no target may be reclaimed. 0 = never.
##
## [b]Distance rather than a timer.[/b] An NPC nobody can see costs the same as one
## being fought, and the ones that accumulate are always the ones left behind — which
## is a fact about where the players are, not about how long it has been.
@export_range(0.0, 2000.0, 1.0) var reclaim_distance: float = 90.0

## Seconds an NPC must have been unseen and un-targeted before reclaim may take it.
##
## Without it, a player who backs through a doorway deletes the thing chasing them.
@export_range(0.0, 300.0, 0.5) var reclaim_grace: float = 8.0

## Whether NPCs a player owns are removed when that player leaves.
@export var clean_up_on_leave: bool = true

@export_group("Perception")

## Physics ticks between one NPC's perception passes. 1 = every tick.
##
## [b]The single biggest cost in this addon, and the one worth spending least on.[/b]
## A line-of-sight raycast per candidate per NPC per tick at ninety NPCs is thousands
## of casts a second for information that changes on a human timescale. Four ticks at
## 64 Hz is 60 ms of staleness, which nobody has ever noticed in a zombie.
@export_range(1, 32, 1) var sense_period_ticks: int = 4

## Most candidate targets one perception pass will consider.
##
## A cap rather than a promise: the nearest are considered first, so raising this
## costs and lowering it only makes a distant target invisible.
@export_range(1, 256, 1) var sense_candidate_cap: int = 32

@export_group("Navigation")

## Whether a spawn point must be on the map's navigation data. See [DotNpcNavData].
##
## [b]On, and it is not a nicety.[/b] An NPC spawned off the navmesh has nowhere to
## path from and stands still for ever, which reads as a broken brain rather than as a
## bad spawn point — the most expensive kind of bug to find.
@export var require_navigable_spawn: bool = true

## How far from a requested point a navigable spawn may be found, in metres.
@export_range(0.0, 100.0, 0.5) var spawn_snap_radius: float = 4.0


func env_prefix() -> String:
	return "DOT_NPC_"


func cli_prefix() -> String:
	return "--npc-"


func validate() -> DotResult:
	if per_kind_cap > 0 and world_budget > 0 and per_kind_cap > world_budget:
		# Not fatal, but it makes the per-kind cap unreachable, which reads as the cap
		# being ignored rather than as two numbers disagreeing.
		return DotResult.fail(
			DotError.CODE_INVALID,
			"per_kind_cap exceeds world_budget, so it can never be reached.",
			"%d vs %d" % [per_kind_cap, world_budget]
		)

	if require_navigable_spawn and spawn_snap_radius <= 0.0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"require_navigable_spawn with a zero snap radius refuses every spawn that is not exactly on a node.",
			"%.1f" % spawn_snap_radius
		)

	return DotResult.success(null)


func describe_summary() -> String:
	return "%d/world %d/kind, %.2fs apart, senses every %d ticks, reclaim %.0fm" % [
		world_budget, per_kind_cap, spawn_interval, sense_period_ticks, reclaim_distance
	]
