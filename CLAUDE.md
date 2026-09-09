# dot-npc

**What an NPC is.** A catalogue of definitions, spawning with a population budget,
health and damage, a perception layer that commits to a target, and navigation
generated from the constants a code-built map was drawn from.

Depends on **dot-core and nothing else**. Not on dot-net, not on dot-combat, not on
dot-map — each of those is a seam a host wires up, and naming any of them would make
this addon fail to parse in a project that does not have it.

## The one idea

**An NPC is a definition, not a scene.** A director deciding whether it can afford four
more zombies must answer that without loading four scenes, and a spawn menu of eighty
entity kinds must not load eighty. So `DotNpcDef` carries the id, the scene path, the
brain path, the cost, the health and the whole perception envelope as plain data, and
the scene is loaded on the one occasion something is actually spawned.

The consequence everything else follows from: **the brain is named by PATH, never by
`class_name`.** A mounted dot-cloud pack arrives long after the project's script cache
was built, so a `class_name` inside one resolves to nothing — measured, and in
`game-dev/CLAUDE.md`. `extends "res://addons/dot_npc/runtime/dot_npc_brain.gd"` works
in a build and in a pack; `extends DotNpcBrain` works in a build only. The fixture in
`fixtures/walker_brain.gd` is deliberately written the supported way, so the suite
cannot pass for a shape the addon does not support.

## Server-authoritative, and not predicted

Everything else in this family is built so a client can predict it. NPCs deliberately
are not, and the reason is stronger than dot-props':

An NPC's position is the output of a pathfinder over a graph, a steering pass and —
for a rigid-body NPC — a physics solver. None of that is reproducible across machines:
iteration order, island membership and the last bits of every float differ. Two runs of
the same horde diverge within a second, so a predicted NPC is a **constantly corrected**
NPC, which looks far worse than one interpolated a few tens of milliseconds behind.

So the server owns every NPC, the client draws what it is told, and `DotNpcNetSync`
says what crosses the wire. Its `apply()` carries the warning three games in this family
have needed: never write a received position onto something the local machine is
simulating. On a client every NPC is a mirror and it is always safe; the machine where
it is wrong is the server, and a bridge running one code path for both would do it.

## Layout

```
addons/dot_npc/
  core/
    dot_npc_def.gd          One kind of NPC. Checkable without loading a scene.
    dot_npc_catalogue.gd    Every kind a server offers. JSON an operator edits.
    dot_npc_limits.gd       A DotConfig: population, pacing, perception, spawns.
    dot_npc_instance.gd     One NPC in the world: node, health, target, brain.
  runtime/
    dot_npc_spawner.gd      The node a game adds. Spawn, sense, think, hurt, reclaim.
    dot_npc_senses.gd       What it can perceive, and what it has committed to.
    dot_npc_brain.gd        The class a game's NPC script extends, by path.
  nav/
    dot_npc_nav_data.gd     Where an NPC may stand, plus the staleness digest.
    dot_npc_nav_builder.gd  Generates that from a map's own constants.
    dot_npc_nav_graph.gd    A* over it, and the path a follower walks.
    dot_npc_path.gd         A path being walked. Following is not searching.
  net/
    dot_npc_net_sync.gd     What replicates, as strings. Never names dot-net.
```

## Navigation was the first decision and it is not a free one

Godot's own answer is `NavigationRegion3D` baking a `NavigationMesh` from source
geometry at edit time. That is right for a game whose maps are authored in a scene, and
**this family's are not**: every map here is a script that builds boxes from constants,
so at edit time the scene is an empty node and there is nothing to bake.

So navigation follows dot-timer's zones exactly. `DotNpcNavBuilder` takes the map's own
walkable rectangles and obstacle boxes — *the same constants the geometry was built
from* — and produces a point graph. `DotNpcNavData.source_digest` is a hash of those
constants, and a game's suite fails when it no longer matches. **A navmesh that has
drifted from its geometry is an NPC walking through a wall, and it is invisible until a
person watches one do it.**

That decision is also what makes a **delivered** map able to have NPCs at all. A map
arriving in a mounted pack cannot be baked on the client — there is no editor there — so
the nav data has to be content, in the pack, beside the zones.

Three things about the builder that are not obvious:

- **A height difference greater than half a spacing is not a neighbour.** Without it a
  walkway passing over a floor joins to it and an NPC paths through the air. It is the
  single commonest thing wrong with a generated graph and the suite has a two-storey
  case for it.
- **A stair built as steps is two disconnected graphs**, so `add_link()` is not
  optional. A ramp is one floor and is fine; most stairs here are not ramps.
- **Neighbours reach 1.5 spacings.** One spacing misses the diagonal by root two and
  gives right-angled paths; two joins across a wall thin enough to hold no point.

A game with authored geometry should use Godot's navigation instead, and nothing here
stops it: a spawner with no nav data spawns anywhere, and a brain that owns a
`NavigationAgent3D` paths with that. This exists so that a code-built map is not the one
shape of map that cannot have NPCs.

## Perception commits, and that is the whole class

"Nearest visible enemy, recomputed every tick" is the classic broken NPC. Two players a
metre apart make it turn back and forth for ever; one who steps behind a pillar makes it
forget instantly and walk away mid-swing.

`DotNpcSenses` therefore acquires at one threshold and drops at a weaker one:

- **`switch_ratio` (0.6)** — a rival must be 40% nearer than the committed target before
  the NPC will change its mind. The suite runs forty ticks of two candidates swapping
  which is marginally nearer and asserts **zero** switches.
- **`commitment_grace` (3 s)** — it keeps chasing a target it can no longer perceive,
  measured from the *last sighting* rather than from acquisition. Without it a doorway
  is a perfect escape.
- **A perceived rival ends the grace immediately.** An NPC that ignored the player
  hitting it in order to chase one that left is worse than either behaviour alone.
- **Hearing is checked before sight**, ignores the cone and is usually shorter. An NPC
  that only saw could be walked up behind for ever; one whose hearing equalled its sight
  has no behind at all.

Perception is also the single biggest cost in the addon, so it is **staggered**:
`sense_period_ticks` spreads the passes across ticks, keyed on the NPC's position in the
dictionary rather than on its instance id — ids from one allocation run are consecutive
and would put a whole wave in the same slot, which is the spike again wearing the
appearance of a fix.

## The limits, and why each one exists

Population is the whole cost of an NPC layer, and every number in `DotNpcLimits` exists
because a server without it has the same evening.

| | |
| --- | --- |
| `world_budget` | Counted in `DotNpcDef.cost`, not in bodies. A shambler and a boss do not cost the same. |
| `per_kind_cap` | A budget alone lets a director spend the whole thing on whatever is cheapest, which is how a horde game ends up as ninety identical crawlers. |
| `spawn_interval` | A budget does not stop a runaway director: one that kills one and spawns one can churn as fast as the tick. |
| `burst_cap` | The difference between a director asking for a wave and a bug asking for ten thousand. |
| `reclaim_distance` / `reclaim_grace` | Distance rather than a timer, because the ones that accumulate are the ones left behind. The grace is what stops a player backing through a doorway from deleting the thing chasing them. |
| `sense_period_ticks` | Four ticks at 64 Hz is 60 ms of staleness, which nobody has ever noticed in a zombie. |
| `require_navigable_spawn` | An NPC spawned off the graph has nowhere to path from and stands still for ever, which reads as a broken brain rather than as a bad spawn point. |

**`require_navigable_spawn` with no nav data allows every spawn.** No navigation is not
the same as "off the navigation": a flat arena, a 2D game or one using Godot's own
navigation has no `DotNpcNavData` and every point in it is legal. Refusing there would
make the setting mean "no NPCs on a map with no nav data", which is a server with no
NPCs and a setting that reads as though it should be on.

## Dying and being reclaimed are not the same event

`died` fires while the node still exists, names who did it, and is what a scoring layer
listens to. `removed` fires for every departure including a director tidying up
something nobody could see. A game with only `removed` would either award a kill for the
tidy-up or have to guess.

Health is handled here when dot-combat is absent and handed to it when it is present,
without this addon ever naming dot-combat: a game with combat calls `report_death()`
from its own health component, a game without it calls `damage()`, and both end at the
same signal.

## Four bugs the suite found while this was being written

All four parsed cleanly. All four are shapes `game-dev/CLAUDE.md` already names.

- **`PackedInt32Array` is a value type**, so `_adjacency[a].append(b)` in
  `DotNpcNavGraph.rebuild` appended to a copy and every adjacency list stayed empty.
  Every edge was in the data, `edge_count()` was right, and `find_path` returned empty
  for every pair of points — with nothing erroring, because an empty adjacency list is
  a legitimate thing for an isolated point to have. The two-storey test *passed* while
  this was broken, because it asserts that a path is **not** found: **a test that passes
  for the wrong reason is worse than one that fails.**
- **`DotNpcNavData.snap()` returns the point it was handed when nothing is near it**,
  which is right for a caller nudging a position and exactly wrong for
  `DotNpcSpawner.place()` deciding whether a spawn is legal — the distance from a point
  to itself is zero, so a spawn two hundred metres off the graph measured as perfect.
  It asks `nearest_point()` for an index now.
- **`DotNpcBrain._npc_damaged` was declared, documented and called by nothing.** The
  family's most repeated bug, in a brand new addon. An NPC that never flinches, never
  calls for help and never flees, with no error anywhere. The suite asserts the *hook*
  rather than the signal, which is the only reason it was visible.
- **`String(PackedStringArray)` is not a constructor**, so the digest helper did not
  compile — and its fix carried a second one: the parts are joined with a separator now,
  because concatenating them lets `[1.0, 23.0]` and `[12.0, 3.0]` collide, and two
  different maps sharing a digest is a stale navmesh reporting itself fresh.

And one in the suite itself, worth as much: **an un-awaited call to a coroutine returns
at its first `await`**, so `_test_no_leaked_nodes()` was scheduled to finish after
`get_tree().quit()` and never reported. It looked like a passing suite that was quietly
one check short.

## Validating

```bash
cd godot/dot-npc
ln -s ../../dot-core/addons/dot_core addons/dot_core   # once

godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' -not -path './addons/dot_core/*' | \
  while read f; do godot --headless --path . --check-only --script "res://${f#./}"; done

timeout 120 godot --headless --path . res://examples/npc_selftest.tscn
```

126 checks. Exits non-zero on failure. Run the `--check-only` pass first: a scene whose
script fails to parse **hangs** rather than failing.

## Where a game plugs in

| To change | Where |
| --- | --- |
| What an NPC is | `DotNpcDef` in a `DotNpcCatalogue` |
| How one decides | `DotNpcBrain` subclass, named by path in the definition |
| How many there may be | `DotNpcLimits`, layered like every `DotConfig` |
| What an NPC can perceive | `DotNpcSenses.switch_ratio` / `commitment_grace`, and the per-definition sight and hearing |
| What it perceives | `DotNpcSpawner.set_candidates` — id, position, faction, loudness |
| Where it may stand | `DotNpcNavData`, generated by `DotNpcNavBuilder` from the map's constants |
| Where NPCs are added | `DotNpcSpawner.world_ref`, a `DotNodeRef` |
| What replicates | `DotNpcNetSync.specs()`, resolved by the game's bridge |
| Who a kill belongs to | the `by` on `damage()` / `report_death()` |

## Things deliberately not here

- **No behaviour tree, no state machine, no utility scoring.** That is `dot-npc-ai`,
  a separate addon, so a game that wants a catalogue and a budget does not install a
  decision engine it will not use.
- **No population director.** That is `dot-npc-ai-director`.
- **No animation.** A `DotNpcNetSync.State` is what a client picks one with; picking it
  is the game's.
- **No melee, no ranged attacks, no damage types.** dot-combat is where a weapon lives,
  and an NPC that swings is a brain calling into it.
- **No flying and no swimming.** `DotNpcNavBuilder` generates a walkable graph. A flying
  NPC needs no graph and should steer directly; nothing stops one.
- **No crowd avoidance.** Two NPCs pathing to the same point will stand in each other.
  A separation pass belongs with steering, which is `dot-npc-ai`'s.
- **No 2D.** The nav data, the senses and the brain are all `Vector3`. dot-2d's games
  would want a `Dot2DNpc*` family, exactly as dot-timer is dimension-agnostic and
  dot-fps-controller is not.
