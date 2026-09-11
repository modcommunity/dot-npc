This is the **NPC** asset for TMC's **Dot** collection. It is what you add when you want things in the world that move about on their own.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## An NPC Layer
**An NPC layer for Godot 4.** It gives you a catalogue of definitions, a population budget that keeps a server alive, perception that commits to a target rather than flickering between two, and navigation generated from the constants a code-built map was drawn from.

Depends on **dot-core and nothing else**.

## Server-authoritative, and not predicted

An NPC's position is the output of a pathfinder, a steering pass and, for a rigid-body NPC, a physics solver, none of which is reproducible across machines. A predicted NPC is a constantly corrected NPC. The server owns every NPC; a client draws what it is told, interpolated a few tens of milliseconds behind.

## Installing

Copy `addons/dot_npc/` and [`dot-core`](https://github.com/modcommunity/dot-core)'s `addons/dot_core/` into your project, and enable dot-npc in *Project → Project Settings → Plugins*.

## Five minutes

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
npcs.set_candidates(players_as_candidates())
npcs.tick(delta)
```

A definition:

```gdscript
var zombie := DotNpcDef.make(&"zombie", "res://npcs/zombie.tscn")
zombie.brain_script_path = "res://npcs/zombie_brain.gd"   # a PATH, never a class name
zombie.faction = &"hostile"
zombie.max_health = 100.0
zombie.sight_range = 30.0
zombie.hearing_range = 12.0
zombie.meta = {"speed": 3.4}
catalogue.add(zombie)
```

A brain:

```gdscript
extends "res://addons/dot_npc/runtime/dot_npc_brain.gd"

func _npc_think(delta: float) -> void:
    if not npc.has_target():
        return
    steer_along_path(target_position(), tune(&"speed", 3.0), delta)
```

## Navigation

Every map in this family is built in code from constants, so there is no authored geometry to bake a `NavigationMesh` from. `DotNpcNavBuilder` generates a point graph from the same constants the geometry was built from, and `DotNpcNavData.source_digest` is what a suite compares to catch a map that moved and a graph that did not.

A game with authored geometry should use Godot's own `NavigationRegion3D` instead, and nothing here stops it: a spawner with no nav data spawns anywhere, and a brain that owns a `NavigationAgent3D` paths with that.

What the graph does beyond A*, all of it read out of Recast & Detour and twenty years of shipped navigation-mesh practice:

| | |
| --- | --- |
| **Smoothing** | A two-metre grid can only turn eight ways, so a path across an open room is a visible staircase. `find_smooth_path` removes the corners the world does not have. On by default. |
| **Areas** | A point can be water, a hazard, a doorway. `DotNpcNavFilter` gives an area a cost, so an NPC goes round the pond, and wades when going round is worse. |
| **Flags** | Crouch, jump, avoid, door. `DotNpcDef.nav_exclude_flags` says what one kind of NPC cannot use, because a crouch tunnel is a fact about the map and whether it is a way through is a fact about the NPC. |
| **Partial paths** | An unreachable goal gives the best path toward it rather than nothing, and `DotNpcPath.partial` says so. Following one is correct; believing it arrives is not. |
| **Cover** | The generator records where the walls are and which way they face, so a brain can ask "where do I hide from that" on a map it only has a graph of. |

```gdscript
var filter := DotNpcNavFilter.new()
filter.set_area_cost(DotNpcNavData.AREA_WATER, 6.0)
graph.filter = filter

var path := graph.find_smooth_path(from, to, 2.0, true)   # smoothed, may be partial
var spot := nav.cover_position_from(npc.position(), enemy_position)
```

## The family

`dot-npc` is what an NPC **is**. `dot-npc-ai` is how one **decides**, through behaviour trees, state machines, steering and squads. `dot-npc-ai-director` is the pacing layer: population, and the build-up / peak / fade / relax cycle. Each is a separate addon, so a game that wants a catalogue and a budget does not install a decision engine it will not use.

## Validating

```bash
godot --headless --path . --import
timeout 120 godot --headless --path . res://examples/npc_selftest.tscn
```

183 checks, exits non-zero on failure.

## Licence

MIT.
