# dot-npc

**What an NPC is.** A catalogue of definitions, spawning with a population budget, health and damage, a perception layer that commits to a target, and navigation generated from the constants a code-built map was drawn from. 3D and 2D (the XZ plane).

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to NPCs. How one decides is dot-npc-ai; population and pacing are dot-npc-ai-director.

**Depends on dot-core and nothing else.** Not dot-net, dot-combat or dot-map: each is a seam a host wires up, and naming any of them would make this addon fail to parse in a project that does not have it.

## Read before

| Read | Before |
| --- | --- |
| [docs/runtime.md](docs/runtime.md) | definitions and brains, authority and replication, perception, the limits, death and reclaim, unbinding, 2D, what is deliberately not here |
| [docs/navigation.md](docs/navigation.md) | the builder, smoothing, filters, partial paths, cover, indexing at scale |
| [docs/history.md](docs/history.md) | the bugs, and how each looked |

## Layout

| Path | What |
| --- | --- |
| `addons/dot_npc/core/` | `DotNpcDef` (one kind, checkable without loading a scene), `DotNpcCatalogue` (JSON an operator edits), `DotNpcLimits` (a `DotConfig`), `DotNpcInstance` (one NPC in the world) |
| `addons/dot_npc/runtime/` | `DotNpcSpawner` (the node a game adds: spawn, sense, think, hurt, reclaim), `DotNpcSenses`, `DotNpcBrain` (extended by path) |
| `addons/dot_npc/nav/` | `DotNpcNavData` (points, areas, flags, cover, digest), `DotNpcNavBuilder`, `DotNpcNavFilter`, `DotNpcNavGraph` (A*, smoothing, partial paths), `DotNpcPath` |
| `addons/dot_npc/net/` | `DotNpcNetSync`: what replicates, as strings; never names dot-net |
| `fixtures/` | bodies (3D and 2D) and brains for the suite, written the pack-safe way |
| `examples/npc_selftest.tscn` | the suite |

## Running and testing

- Link `addons/dot_core` once ([development setup](../../docs/development-setup.md)), then the family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)) and `timeout 120 godot --headless --path . res://examples/npc_selftest.tscn`. Exits non-zero on failure.
- The games that run NPCs (game-arena, game-g2gfast, game-playground, game-zombie-zone, game-hungario in 2D) are where most of this addon's bugs were found; run the ones a change touches.

## Rules that bite

**Definitions and runtime**

- A brain is named by PATH in the definition and extends by path, never `class_name`: a mounted pack's globals do not register. [runtime](docs/runtime.md#an-npc-is-a-definition-not-a-scene)
- NPCs are server-authoritative and never predicted. Never write a received position onto something this machine simulates (`DotNpcNetSync.apply`). [runtime](docs/runtime.md#server-authoritative-and-not-predicted)
- `face(d)` is `look_at(position + d)`; `yaw_of` is `rotation.y`. Change one and the round-trip check must still pass. [runtime](docs/runtime.md#face-and-facing-agree)
- Perception commits: `switch_ratio` 0.6, `commitment_grace` 3 s from the last sighting, a perceived rival ends the grace, hearing before sight. [runtime](docs/runtime.md#perception-commits-and-that-is-the-whole-class)
- Sight lines start at `eye_height`, never the feet. [runtime](docs/runtime.md#perception-commits-and-that-is-the-whole-class)
- Stagger keys on dictionary position, never instance id. [runtime](docs/runtime.md#perception-commits-and-that-is-the-whole-class)
- `engaged_at` (busy; refreshed every pass) is not `target_since` (reaction clock; set on change only). [runtime](docs/runtime.md#engaged_at-and-target_since-are-different-questions)
- `sight_scale` scales sight only, never hearing. [runtime](docs/runtime.md#sight_scale-is-per-npc-the-definitions-range-per-kind)
- `require_navigable_spawn` with no nav data allows every spawn; judging a spawn uses `nearest_point()`, never `snap()`. [runtime](docs/runtime.md#the-limits-and-why-each-one-exists)
- `died` is a kill, `removed` is any departure. [runtime](docs/runtime.md#dying-and-being-reclaimed-are-not-the-same-event)
- The spawner `unbind()`s every brain on `remove()` and on its own `NOTIFICATION_PREDELETE` (not `_exit_tree`); a brain subclass drops what it built in `_npc_unbound()`. [runtime](docs/runtime.md#a-brain-and-its-npc-point-at-each-other-so-the-spawner-lets-go-of-both)
- 2D is `Vector3(x, 0, y)`; `two_dimensional` is one flag; `spawn`/`spawn_2d` refuse the wrong body and free it; a 2D definition sets `require_line_of_sight = false`. [runtime](docs/runtime.md#2d-a-2d-world-is-the-xz-plane)

**Navigation**

- Nav data is generated from the map's constants and checked by `source_digest` in the game's suite; a drifted navmesh is an NPC in a wall. [navigation](docs/navigation.md#generated-from-the-maps-constants-not-baked)
- Builder: height gap over half a spacing is not a neighbour; stairs of steps need `add_link()`; neighbours reach 1.5 spacings; "the same place" is by distance. [navigation](docs/navigation.md#the-builder)
- `can_walk_straight` asks connectivity (edges the builder drew), never proximity. [navigation](docs/navigation.md#smoothing-because-a-grid-can-only-turn-eight-ways)
- Filters apply to the start point too; flags are per kind (`nav_exclude_flags`), costs per area. [navigation](docs/navigation.md#areas-and-flags-because-passable-is-two-questions)
- A partial path never has the goal appended; a finished partial path waits for its interval; unreachable goals are answered from the component labels. [navigation](docs/navigation.md#partial-paths-because-standing-still-is-not-an-answer)
- Indexed lookups must return the brute-force scan's answer, ties included (lowest index wins). [navigation](docs/navigation.md#at-scale)
- `PackedInt32Array` in a dictionary or array is a copy; append through a local and write it back. [history](docs/history.md)

## Where a game plugs in

| To change | Where |
| --- | --- |
| What an NPC is | `DotNpcDef` in a `DotNpcCatalogue` |
| An NPC in a 2D world | `DotNpcSpawner.spawn_2d`, plus `two_dimensional`. See game-hungario |
| How one decides | `DotNpcBrain` subclass, named by path in the definition |
| How many there may be | `DotNpcLimits`, layered like every `DotConfig` |
| What an NPC can perceive | `DotNpcSenses.switch_ratio` / `commitment_grace`, and the per-definition sight, hearing and `eye_height` |
| What it perceives | `DotNpcSpawner.set_candidates`: id, position, faction, loudness |
| Where it may stand | `DotNpcNavData`, generated by `DotNpcNavBuilder` from the map's constants |
| What one area of the map costs to cross | `DotNpcNavFilter.set_area_cost`, per NPC |
| What one kind of NPC cannot traverse | `DotNpcDef.nav_exclude_flags` |
| Whether paths are smoothed or may stop short | `DotNpcSpawner.smooth_paths` / `allow_partial_paths` |
| Where cover is | `DotNpcNavBuilder.generate_cover` / `cover_range`, or `DotNpcNavData.add_cover` from a generator that has the geometry |
| Where NPCs are added | `DotNpcSpawner.world_ref`, a `DotNodeRef` |
| What replicates | `DotNpcNetSync.specs()`, resolved by the game's bridge |
| Who a kill belongs to | the `by` on `damage()` / `report_death()` |

Deliberately not here: decisions (dot-npc-ai), a population director, animation, attacks and damage types (dot-combat), flying and swimming, crowd avoidance, dynamic obstacles, sniper spots. [runtime](docs/runtime.md#deliberately-not-here), [navigation](docs/navigation.md#not-here)
