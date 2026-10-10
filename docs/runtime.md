# The NPC at runtime

## An NPC is a definition, not a scene

A director deciding whether it can afford four more zombies must answer that without loading four scenes, and a spawn menu of eighty entity kinds must not load eighty. So `DotNpcDef` carries the id, the scene path, the brain path, the cost, the health and the whole perception envelope as plain data, and the scene is loaded on the one occasion something is actually spawned.

The consequence everything else follows from: **the brain is named by PATH, never by `class_name`.** A mounted dot-cloud pack arrives long after the project's script cache was built, so a `class_name` inside one resolves to nothing ([bugs-found](../../../docs/bugs-found.md)). `extends "res://addons/dot_npc/runtime/dot_npc_brain.gd"` works in a build and in a pack; `extends DotNpcBrain` works in a build only. `fixtures/walker_brain.gd` is deliberately written the supported way, so the suite cannot pass for a shape the addon does not support.

## Server-authoritative, and not predicted

Everything else in this family is built so a client can predict it. NPCs deliberately are not, and the reason is stronger than dot-props':

An NPC's position is the output of a pathfinder over a graph, a steering pass and, for a rigid-body NPC, a physics solver. None of that is reproducible across machines: iteration order, island membership and the last bits of every float differ. Two runs of the same horde diverge within a second, so a predicted NPC is a **constantly corrected** NPC, which looks far worse than one interpolated a few tens of milliseconds behind.

So the server owns every NPC, the client draws what it is told, and `DotNpcNetSync` says what crosses the wire. Its `apply()` carries the warning three games in this family have needed: never write a received position onto something the local machine is simulating. On a client every NPC is a mirror and it is always safe; the machine where it is wrong is the server, and a bridge running one code path for both would do it.

## `face` and `facing` agree

`DotNpcBrain.face(d)` is `look_at(position + d)`: `look_at` points -Z at its target and `facing()` reads -Z. `DotNpcNetSync.yaw_of` returns the node's own `rotation.y`. Both were once half a turn out in opposite directions, which cancelled on a client's screen while every server-side sight cone pointed behind its NPC ([history](history.md)). The replication section asserts the round trip: told to face +X, an NPC faces +X, and a client given its yaw faces +X too.

## Perception commits, and that is the whole class

"Nearest visible enemy, recomputed every tick" is the classic broken NPC. Two players a metre apart make it turn back and forth for ever; one who steps behind a pillar makes it forget instantly and walk away mid-swing.

`DotNpcSenses` therefore acquires at one threshold and drops at a weaker one:

- **`switch_ratio` (0.6)**: a rival must be 40% nearer than the committed target before the NPC will change its mind. The suite runs two candidates swapping which is marginally nearer and asserts **zero** switches.
- **`commitment_grace` (3 s)**: it keeps chasing a target it can no longer perceive, measured from the *last sighting* rather than from acquisition. Without it a doorway is a perfect escape.
- **A perceived rival ends the grace immediately.** An NPC that ignored the player hitting it in order to chase one that left is worse than either behaviour alone.
- **Hearing is checked before sight**, ignores the cone and is usually shorter. An NPC that only saw could be walked up behind for ever; one whose hearing equalled its sight has no behind at all.
- **The sight line starts at `DotNpcDef.eye_height`** (1.5 m by default, `"eye"` in a catalogue), never at `npc.position()`, which is the feet: a ray that starts on a surface hits it at distance zero, and every NPC on a floor with line of sight on was blind.

Perception is the single biggest cost in the addon, so it is **staggered**: `sense_period_ticks` spreads the passes across ticks, keyed on the NPC's position in the dictionary rather than on its instance id. Ids from one allocation run are consecutive and would put a whole wave in the same slot, which is the spike again wearing the appearance of a fix.

### `sight_scale` is per NPC, the definition's range per kind

`DotNpcInstance.sight_scale` multiplies `DotNpcDef.sight_range` for one NPC. How far a kind can see belongs in the catalogue; how attentive this one is belongs to its character, and dot-npc-ai's brain writes the character's `alertness` here. Sight only: hearing is a loudness the game measured, and scaling it would be an NPC that hears a footstep further than the footstep travels.

### `engaged_at` and `target_since` are different questions

| | |
| --- | --- |
| `engaged_at` | **Refreshed on every pass in which the target is perceived.** "Is this NPC still busy?": what `DotNpcLimits.reclaim_grace` is measured from. |
| `target_since` | **Set when `target_id` changes, and not while it is held.** "How long has it known about this one?": what a reaction time is measured from. |

Measuring a reaction time from `engaged_at` never finishes reacting (dot-npc-ai's `has_reacted()` was false for ever that way). The subtle half: **re-perceiving the same target after a gap** is not a new commitment, so `update_target` only moves `target_since` when the id actually changes; restarting the clock there is an NPC that never finishes reacting to somebody who keeps stepping behind a pillar.

## The limits, and why each one exists

Population is the whole cost of an NPC layer, and every number in `DotNpcLimits` exists because a server without it has the same evening.

| | |
| --- | --- |
| `world_budget` | Counted in `DotNpcDef.cost`, not in bodies. A shambler and a boss do not cost the same. |
| `per_kind_cap` | A budget alone lets a director spend the whole thing on whatever is cheapest, which is how a horde game ends up as ninety identical crawlers. |
| `spawn_interval` | A budget does not stop a runaway director: one that kills one and spawns one can churn as fast as the tick. |
| `burst_cap` | The difference between a director asking for a wave and a bug asking for ten thousand. |
| `reclaim_distance` / `reclaim_grace` | Distance rather than a timer, because the ones that accumulate are the ones left behind. The grace is what stops a player backing through a doorway from deleting the thing chasing them. |
| `sense_period_ticks` | Four ticks at 64 Hz is 60 ms of staleness, which nobody has ever noticed in a zombie. |
| `require_navigable_spawn` | An NPC spawned off the graph has nowhere to path from and stands still for ever, which reads as a broken brain rather than as a bad spawn point. |

**`require_navigable_spawn` with no nav data allows every spawn.** No navigation is not the same as "off the navigation": a flat arena, a 2D game or one using Godot's own navigation has no `DotNpcNavData` and every point in it is legal. Refusing there would make the setting mean "no NPCs on a map with no nav data".

Deciding whether a spawn is on the graph uses `nearest_point()` for an index, never `DotNpcNavData.snap()`: `snap` returns the point it was handed when nothing is near, which is right for nudging a position and makes a spawn two hundred metres off the graph measure as perfect.

## Dying and being reclaimed are not the same event

`died` fires while the node still exists, names who did it, and is what a scoring layer listens to. `removed` fires for every departure including a director tidying up something nobody could see. A game with only `removed` would either award a kill for the tidy-up or have to guess.

Health is handled here when dot-combat is absent and handed to it when it is present, without this addon ever naming dot-combat: a game with combat calls `report_death()` from its own health component, a game without it calls `damage()`, and both end at the same signal. `DotNpcBrain._npc_damaged` is called on damage; the suite asserts the *hook* rather than the signal, because a hook called by nothing is the family's most repeated bug.

## A brain and its NPC point at each other, so the spawner lets go of both

`DotNpcBrain.npc` holds the instance and the instance's `brain` holds the brain; `DotNpcAiBrain.context` holds a context whose `brain` holds the brain back. Two `RefCounted`s that point at each other are never freed, and clearing one end reads exactly like the fix. The path that leaks hardest never calls `remove()` at all: a world is torn down by freeing its nodes.

So `DotNpcBrain.unbind()` clears `npc`, `director` and `path` after calling `_npc_unbound()`, where a subclass drops whatever it built around them (`DotNpcAiBrain` drops its context, tree, machine and blackboard), and the spawner calls it from `remove()` and, for every NPC still alive, from its `NOTIFICATION_PREDELETE`. Not `_exit_tree`, because a spawner reparented during a map change must keep its NPCs thinking. `DotVehicleSpawner._unbind` is the same shape for the same reason.

## 2D: a 2D world is the XZ plane

`DotNpcSpawner.spawn` places a `Node3D` and `spawn_2d` places a `Node2D`. Everything either side of that (the catalogue, the budget, the per-kind cap, the spawn interval, perception, commitment, reclaim and the brain) is the same code, because none of it is about dimension.

**The mapping is one line: a 2D point `(x, y)` is `Vector3(x, 0, y)`.** `DotNpcSenses` compares 3D distances, `DotNpcAiSteering` returns 3D directions, and `DotNpcNavData` is a graph of 3D points, all of which are exactly right on a plane where one component never moves and all of which would have to be rewritten for a `Vector2`. `DotNpcInstance.to_plane` / `from_plane` are the conversion and `position()` answers in the plane for either kind of body.

`DotNpcInstance.node` is therefore typed **`Node`**. `position()`, `facing()` and `DotNpcBrain.steer_toward` / `face` / `halt` all branch on the body: a `RigidBody2D` gets a velocity, a `CharacterBody2D` gets `move_and_slide`, and a plain `Node2D` is moved. There is no gravity in the 2D branch, because a top-down world has none.

**A 2D definition should set `require_line_of_sight = false`.** There is no 3D physics world to cast through; `_has_line_of_sight` answers "clear" rather than blinding every NPC, and saying so in the definition makes it a decision rather than a fallback nobody noticed.

**`two_dimensional` is one flag rather than a 2D twin of everything that takes a point.** It is set once beside `authoritative`, because a spawner serves one world and a world has one dimension. `spawn_group` reads it (a second copy of the ring arithmetic is a second place the deterministic layout could drift), and so does `DotNpcDirector`. `spawn` and `spawn_2d` stay separate and are *not* switched by it: a caller holding a `Vector3` and one holding a `Vector2` are different callers, and a signature that took either would take anything.

**Asking for the wrong dimension is refused without leaking.** A 3D NPC through `spawn_2d` and a 2D one through `spawn` both return null, and the instantiated scene is freed. The suite checks the child count either side of both refusals.

## Deliberately not here

- **No behaviour tree, no state machine, no utility scoring.** That is dot-npc-ai, a separate addon, so a game that wants a catalogue and a budget does not install a decision engine it will not use.
- **No population director.** That is dot-npc-ai-director.
- **No animation.** A `DotNpcNetSync.State` is what a client picks one with; picking it is the game's.
- **No melee, no ranged attacks, no damage types.** dot-combat is where a weapon lives, and an NPC that swings is a brain calling into it.
- Navigation's own gaps are in [navigation.md](navigation.md#not-here).
