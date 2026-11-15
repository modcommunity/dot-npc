Computer-controlled characters for a Godot 4 game. dot-npc gives you a catalogue of NPC definitions, a population budget that keeps a server alive, perception that sticks to one target instead of flickering between two, and navigation generated from the constants a code-built map was drawn from. It needs only [dot-core](https://github.com/gamespice-platform/core). Part of TMC's open source **Dot** collection (MIT licence).

> Built with Claude Code. Every addon has a headless test suite and the suites pass, but little of this has met real players yet. Please report rough edges.

## The server owns every NPC

An NPC's position comes from a pathfinder, a steering pass and, for a rigid-body NPC, a physics solver. None of those give the same answer on two machines, so a predicted NPC would be corrected all the time. The server runs every NPC. A client draws what it is told, a few tens of milliseconds in the past.

## Install

Copy `addons/dot_npc/` and dot-core's `addons/dot_core/` into your project and enable dot-npc under **Project > Project Settings > Plugins**.

## Quick start

```gdscript
var npcs := DotNpcSpawner.new()
npcs.authoritative = true                       # on the server only
npcs.catalogue = catalogue
npcs.limits = DotNpcLimits.new()
npcs.world_ref = DotNodeRef.of_path(^"../World")
add_child(npcs)

# Once per map change:
npcs.set_nav_data(load("res://maps/pg_lobby.nav.tres"))

# Every simulated tick:
npcs.set_candidates(players_as_candidates())    # who the NPCs may notice
npcs.tick(delta)
```

`npcs.candidates()` returns the list last handed in (read only), for code that needs to know who the NPCs can see.

A definition says what one kind of NPC is:

```gdscript
var zombie := DotNpcDef.make(&"zombie", "res://npcs/zombie.tscn")
zombie.brain_script_path = "res://npcs/zombie_brain.gd"   # a file path, not a class name
zombie.faction = &"hostile"
zombie.max_health = 100.0
zombie.sight_range = 30.0
zombie.hearing_range = 12.0
zombie.meta = {"speed": 3.4}
catalogue.add(zombie)
```

A brain says what it does each tick:

```gdscript
extends "res://addons/dot_npc/runtime/dot_npc_brain.gd"

func _npc_think(delta: float) -> void:
    if not npc.has_target():
        return
    steer_along_path(target_position(), tune(&"speed", 3.0), delta)
```

## Population limits

`DotNpcLimits` is a `DotConfig`, so an operator can change it without a rebuild: defaults, JSON file, `DOT_NPC_*` environment, `--npc-*` command line.

| Setting | Default | What it does |
| --- | --- | --- |
| `world_budget` | 96 | Most NPCs alive at once, counted in each definition's `cost`. 0 = unlimited. |
| `per_kind_cap` | 24 | Most of any one kind. Stops a director spending the whole budget on the cheapest kind. 0 = unlimited. |
| `spawn_interval` | 0.1 | Seconds between spawns from one spawner. 0 = no wait. |
| `burst_cap` | 12 | Most NPCs one `spawn_group` call may create. Default 12, 0 = unlimited. |
| `reclaim_distance` | 90.0 | Metres beyond which an NPC with no target may be removed. 0 = never. |
| `reclaim_grace` | 8.0 | Seconds an NPC must have gone unseen and un-targeted before it may be removed. |
| `clean_up_on_leave` | true | Remove the NPCs a player owns when that player leaves. |
| `sense_period_ticks` | 4 | Ticks between one NPC's perception passes. 1 = every tick. |
| `sense_candidate_cap` | 32 | Most candidate targets one perception pass considers, nearest first. Default 32, 0 = unlimited. |
| `sense_quiet_mult` | 1 | An NPC with no target senses this many times less often. 1 = off. Keep it at 2 to 4 if used. |
| `require_navigable_spawn` | true | A spawn point must be on the map's navigation data. |
| `spawn_snap_radius` | 4.0 | Metres to search for a navigable spot near a requested point. |
| `think_workers` | 0 | Worker threads for brains that can split thinking. 0 = inline, -1 = automatic. The result is the same either way. |

## Navigation

Maps in this family are built in code from constants, so there is no authored geometry to bake a `NavigationMesh` from. `DotNpcNavBuilder` generates a point graph from the same constants the geometry used. `DotNpcNavData.source_digest` lets a test notice when a map changed but its graph did not.

A game with authored geometry can use Godot's own `NavigationRegion3D` instead. A spawner with no navigation data spawns anywhere, and a brain that owns a `NavigationAgent3D` paths with that.

On top of plain A* the graph adds:

| Feature | What it does |
| --- | --- |
| Smoothing | A grid turns only eight ways, so a path across an open room zigzags. `find_smooth_path` removes corners the world does not have. On by default. |
| Areas | A point can be water, a hazard or a doorway. `DotNpcNavFilter` gives an area a cost, so NPCs walk round a pond and wade only when going round is worse. |
| Flags | Crouch, jump, avoid, door. `DotNpcDef.nav_exclude_flags` lists what one kind of NPC cannot use. |
| Partial paths | An unreachable goal gives the best path toward it, and `DotNpcPath.partial` says so. |
| Cover | The generator records where walls are and which way they face, so a brain can ask where to hide from an enemy. |

```gdscript
var filter := DotNpcNavFilter.new()
filter.set_area_cost(DotNpcNavData.AREA_WATER, 6.0)
graph.filter = filter

var path := graph.find_smooth_path(from, to, 2.0, true)   # smoothed, may be partial
var spot := nav.cover_position_from(npc.position(), enemy_position)
```

## The family

| Addon | Role |
| --- | --- |
| dot-npc | What an NPC is: definitions, budget, perception, navigation. |
| [dot-npc-ai](https://github.com/gamespice-platform/npc-ai) | How one decides: behaviour trees, state machines, steering, squads. |
| [dot-npc-ai-director](https://github.com/gamespice-platform/npc-ai-director) | Pacing: population and the build-up, peak, fade, relax cycle. |

Each is separate, so a game that wants a catalogue and a budget does not install a decision engine.

## More

[docs/navigation.md](docs/navigation.md), [docs/runtime.md](docs/runtime.md) and [docs/history.md](docs/history.md).

## Testing

```bash
godot --headless --path . --import
timeout 120 godot --headless --path . res://examples/npc_selftest.tscn
```

Exits non-zero on failure.

## Licence

MIT. See [LICENSE](LICENSE).
