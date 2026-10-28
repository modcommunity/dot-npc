@tool
class_name DotNpcLimits
extends DotConfig

## How many NPCs may exist, how fast they may arrive, and how hard they may think.
## Population is the whole cost of an NPC layer: a director that spawns faster than players kill
## turns a two-millisecond step into two hundred. A [DotConfig], so an operator retunes it without a rebuild.

@export_group("Population")

## Most NPCs in the world at once, counted in [member DotNpcDef.cost]. 0 = unlimited.
@export_range(0, 10000, 1) var world_budget: int = 96

## Most of any one kind at once. 0 = unlimited.
## Not the budget: a budget alone lets a director spend it all on the cheapest kind.
@export_range(0, 1000, 1) var per_kind_cap: int = 24

## Seconds between spawns from one spawner. 0 = no wait.
## Stops a runaway director: a budget alone does not when it kills one and spawns one every tick.
@export_range(0.0, 10.0, 0.01) var spawn_interval: float = 0.1

## Most NPCs one call to [method DotNpcSpawner.spawn_group] may create.
@export_range(1, 200, 1) var burst_cap: int = 12

@export_group("Lifetime")

## Metres beyond which an NPC with no target may be reclaimed. 0 = never.
## Distance, not a timer: the NPCs that accumulate are the ones left behind, which depends on where players are.
@export_range(0.0, 2000.0, 1.0) var reclaim_distance: float = 90.0

## Seconds an NPC must have been unseen and un-targeted before reclaim may take it.
##
## Without it, a player who backs through a doorway deletes the thing chasing them.
@export_range(0.0, 300.0, 0.5) var reclaim_grace: float = 8.0

## Whether NPCs a player owns are removed when that player leaves.
@export var clean_up_on_leave: bool = true

@export_group("Perception")

## Physics ticks between one NPC's perception passes. 1 = every tick.
## The biggest cost here: line-of-sight casts per candidate per NPC per tick. Four ticks at
## 64 Hz is 60 ms of staleness nobody notices.
@export_range(1, 32, 1) var sense_period_ticks: int = 4

## Most candidate targets one perception pass will consider.
## A cap, not a promise: the nearest go first, so lowering it only hides a distant target.
@export_range(1, 256, 1) var sense_candidate_cap: int = 32

## An NPC with no target whose last pass found nothing within reach senses every
## `sense_period_ticks * sense_quiet_mult` ticks. 1 = off.
## A new arrival is noticed that much later, so keep it small (2-4).
@export_range(1, 16, 1) var sense_quiet_mult: int = 1

@export_group("Navigation")

## Whether a spawn point must be on the map's navigation data. See [DotNpcNavData].
## On: an NPC off the navmesh stands still for ever, which reads as a broken brain.
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
