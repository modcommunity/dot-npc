# Navigation

## Generated from the map's constants, not baked

Godot's own answer is `NavigationRegion3D` baking a `NavigationMesh` from source geometry at edit time. That is right for a game whose maps are authored in a scene, and **this family's are not**: every map here is a script that builds boxes from constants, so at edit time the scene is an empty node and there is nothing to bake.

So navigation follows dot-timer's zones exactly. `DotNpcNavBuilder` takes the map's own walkable rectangles and obstacle boxes (*the same constants the geometry was built from*) and produces a point graph. `DotNpcNavData.source_digest` is a hash of those constants, and a game's suite fails when it no longer matches. **A navmesh that has drifted from its geometry is an NPC walking through a wall, and it is invisible until a person watches one do it.** The digest joins its parts with a separator: concatenation lets `[1.0, 23.0]` and `[12.0, 3.0]` collide, and two maps sharing a digest is a stale navmesh reporting itself fresh.

That decision is also what makes a **delivered** map able to have NPCs at all. A map arriving in a mounted pack cannot be baked on the client (there is no editor there), so the nav data has to be content, in the pack, beside the zones.

A game with authored geometry should use Godot's navigation instead, and nothing here stops it: a spawner with no nav data spawns anywhere, and a brain that owns a `NavigationAgent3D` paths with that. This exists so that a code-built map is not the one shape of map that cannot have NPCs.

## The builder

- **A height difference greater than half a spacing is not a neighbour.** Without it a walkway passing over a floor joins to it and an NPC paths through the air. It is the single commonest thing wrong with a generated graph and the suite has a two-storey case for it.
- **A stair built as steps is two disconnected graphs**, so `add_link()` is not optional. A ramp is one floor and is fine; most stairs here are not ramps.
- **Neighbours reach 1.5 spacings.** One spacing misses the diagonal by root two and gives right-angled paths; two joins across a wall thin enough to hold no point.
- **"The same place" is by distance (half a step), never by rounding to a grid key.** Floors laid from different corners have grids offset by a fraction of a step; rounding merged a room's last row with a street's first 0.9 m away, dropped one, and cut the room off from the street. The suite's "navigation builder" case lays a room, a door and a street from three corners.

## What a path is worth

The graph half was a search and nothing else at first: A*, a chain of grid points, and a follower that walked them. What follows came from reading Recast & Detour and a shipped engine's navigation-mesh code.

### Smoothing, because a grid can only turn eight ways

A two-metre grid crossing an open room produces a staircase: an NPC visibly zig-zags across ground with nothing in it, and it is the first thing anybody watching one notices. Detour solves the polygon version with the funnel algorithm (`dtFindStraightPath`); `dtPathCorridor::optimizePathVisibility` is the incremental form. `DotNpcNavGraph.smooth_path` is the point-graph version: from each kept waypoint, reach as far ahead as is still walkable in a straight line and drop everything between.

**The naive walkability test passes straight through walls.** "Is every sample along the line near some point" is true inside any wall thin enough to have graph points on both sides of it. The fix is not a tighter threshold, which only moves the wall thickness at which it breaks; it is a different question. The builder already refused to connect two points whose straight line crossed an obstacle, so `can_walk_straight` walks the nearest-point sequence along the line and requires each step to be an edge the builder actually drew. Connectivity, not proximity, and the answer is exact rather than a margin.

That is why `DotNpcNavData.grid_spacing` exists. Sampling has to happen at under half a cell or the nearest point can skip one, and `point_radius` is not that number: it is how far off the mesh an NPC may stand, which a generator may set to anything.

### Areas and flags, because "passable" is two questions

`DotNpcNavFilter` is Detour's `dtQueryFilter` in the shape a point graph needs.

- **Cost, for things that are passable and unpleasant.** A ban cannot express "go round the water unless going round is much worse", and an NPC that will never step in water stands at the edge of a puddle for ever when the puddle is the only way through. The suite has both halves: at a cost of 20 it walks round, at 1.05 it wades.
- **Flags, for things that are impassable to *this* NPC.** A crouch tunnel is a fact about the map; whether it is a way through is a fact about what is trying to use it. So the flag set lives on `DotNpcDef.nav_exclude_flags` and the spawner builds one filter per kind: one graph serves every NPC on the map and they do not agree about it.

The filter is applied to the **start point** as well as to the search. Without that, an NPC standing at the mouth of a tunnel it may not use snaps onto a point it may not occupy, and every path from it fails at the first edge, which reads as a broken graph rather than as a filter doing its job.

### Partial paths, because standing still is not an answer

Detour returns its best guess with `DT_PARTIAL_RESULT` rather than nothing. `find_path` does the same on request: the search already tracks the closest node it reached, so the partial path is free. `DotNpcPath.partial` carries it to the brain, because **following a partial path is correct and believing it ends at the goal is not**: a brain that cannot tell the difference repaths to an unreachable target for ever.

The caller's own goal is deliberately *not* appended to a partial path. Appending it puts the unreachable position on the end of a path that stops short on purpose, and every follower walks the last leg straight through the wall.

**An unreachable goal is the most expensive question a graph can be asked, and a crowd asks it every tick.** A* proves a goal unreachable by visiting everything the start can reach. So `DotNpcPath.needs_repath` lets a finished PARTIAL path wait for the interval (or for the goal to move) like any other path, and `DotNpcNavGraph` labels its connected pieces at `rebuild`, so a goal in another piece goes straight to the nearest point in the start's piece (the point the full search would have stopped at) without the search. The shortcut is filter-blind and steps aside when a filter is set.

### Cover, because a runtime cannot raycast a map it was handed as a graph

A shipped navigation mesh computes hiding spots at generation time and stores them; here that is the only option. Nothing at runtime has the geometry (the map was built from constants and shipped as points), so if the generator does not write cover down, nothing can ever answer "where can I hide from that".

`DotNpcNavData` keeps cover as its own list rather than as a point attribute, because the useful spot is the corner of an area, not its middle. Each spot records **the direction the wall lies in**, so the runtime question ("is this spot covered from over there") is a dot product.

`_mark_cover` records one spot per point, not one per obstacle. A point in an inside corner has two walls and would otherwise produce two spots in the same place; the query picks the nearest wall to the threat anyway. Only `IN_COVER` is generated: sniper spots and exposed ledges need long visibility traces over the whole map, and a generator with the geometry in front of it can add them; the flags exist so it can.

## At scale

A campaign map is thousands of points (a 120 by 80 metre street at one metre is over six thousand), and forty NPCs repathing every second and a half spent a server's tick in loops written for hundreds. All four are indexed: points by (x, z) bucket in `DotNpcNavData` (built lazily, dropped by `add_point`, `validate` and `invalidate_index`), obstacles by cell in the builder, neighbours by bucket, and A*'s open list is a binary heap ordered by priority then push order.

**The answers are the scan's answers, ties included.** The lowest index still wins at an equal distance, and the edges are still connected in the same order, because a follower that snapped to a different one of two equidistant points depending on how an index was laid out would path differently on two machines. "navigation at scale" in the suite compares random lookups with a brute-force scan.

## Not here

- **No flying and no swimming.** The builder generates a walkable graph. A flying NPC needs no graph and should steer directly.
- **No crowd avoidance.** Two NPCs pathing to the same point will stand in each other; separation is steering, which is dot-npc-ai's.
- **No dynamic obstacles.** A door that closes does not re-cut the graph. Detour has `dtTileCache` for it; here the honest answer is a `Flag.DOOR` on the points under the door and a filter per NPC, which says who may use it and not whether it is open.
- **No sniper spots or exposed ledges** generated (see cover above).
