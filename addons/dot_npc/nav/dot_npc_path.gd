class_name DotNpcPath
extends RefCounted

## A path being walked: the waypoints, where along them the NPC is, and when to repath.
##
## [b]Separate from [DotNpcNavGraph] because following is not searching.[/b] A search
## is expensive and happens rarely; following happens every tick and is three
## subtractions. Putting them in one class is what makes a game repath every tick
## because that was the only call available.
##
## [b]Advancing is a distance test on the horizontal plane, deliberately.[/b] A
## waypoint on a floor an NPC is standing on is a metre below its eyes and, on a
## slope, further; a 3D distance test against a tolerance that works on the flat then
## never fires on a ramp, and the NPC grinds into the waypoint for ever. The vertical
## component is the map's business, not the follower's.

## The world positions to walk, in order. First is where the path was requested from.
var points: PackedVector3Array = PackedVector3Array()

## Index of the waypoint currently being walked toward.
var index: int = 0

## How close, horizontally, counts as having arrived at a waypoint.
var arrive_radius: float = 1.2

## Simulated seconds when this path was computed. What a repath interval is measured
## against, and never a wall clock.
var computed_at: float = 0.0

## Where the goal was when the path was computed.
##
## [b]The repath trigger that matters.[/b] A time-based repath alone is either too
## slow to follow a running player or fast enough to search every few ticks for
## ninety NPCs; a goal that has moved further than this is the cheap question that
## answers "is this path still about the right thing".
var goal_at_compute: Vector3 = Vector3.ZERO

## Whether the points stop short of the goal because it could not be reached.
##
## Set by whatever produced them — the spawner copies
## [member DotNpcNavGraph.last_partial] — and read by a brain that would otherwise
## repath to an unreachable target for ever. [b]Following a partial path is correct;
## believing it ends at the goal is not.[/b]
var partial: bool = false


## Until when (the spawner's clock) this follower's paths come unsmoothed. See [method go_rough].
var rough_until: float = -INF


## Drops the path and asks for the graph's own corners, unsmoothed, for [param seconds].
##
## [b]For a follower stuck on a corner its smoothed path cut.[/b] Smoothing asks whether the
## straight line stays on the graph's edges, which a coarse graph answers yes for a line that
## clips a door jamb thinner than its spacing: a zombie on the ballpark pressed into a jamb for
## minutes. The raw path keeps to the points the builder placed clear of everything; a brain
## that notices it is not moving calls this.
##
## While rough, a waypoint counts as reached only within [constant ROUGH_ARRIVE] metres:
## turning for the next corner at [member arrive_radius] (1.2 m) out cut the same door jamb.
func go_rough(now: float, seconds: float = 4.0) -> void:
	if _arrive_before < 0.0:
		_arrive_before = arrive_radius
	arrive_radius = minf(arrive_radius, ROUGH_ARRIVE)
	rough_until = now + seconds
	clear()


## Whether paths for this follower are unsmoothed at [param now]; puts the arrive radius back
## once they are not.
func is_rough(now: float) -> bool:
	if now < rough_until:
		return true

	if _arrive_before >= 0.0:
		arrive_radius = _arrive_before
		_arrive_before = -1.0

	return false


const ROUGH_ARRIVE := 0.5
var _arrive_before: float = -1.0


func set_points(p_points: PackedVector3Array, now: float, goal: Vector3) -> void:
	points = p_points
	index = 1 if p_points.size() > 1 else 0
	computed_at = now
	goal_at_compute = goal
	# Cleared here rather than left to the caller. set_points is the only way new
	# points arrive, so a flag that survived one would describe the previous path —
	# and "this path is partial" is exactly the kind of stale answer that reads as
	# correct.
	partial = false


func is_empty() -> bool:
	return points.is_empty()


func is_finished() -> bool:
	return points.is_empty() or index >= points.size()


## The point currently being walked toward, or [param fallback] when there is none.
func current(fallback: Vector3 = Vector3.ZERO) -> Vector3:
	return points[index] if not is_finished() else fallback


## Advances past any waypoint [param position] has reached. Returns the current one.
func advance(position: Vector3, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	while not is_finished():
		var to_next := points[index] - position
		to_next.y = 0.0

		if to_next.length() > arrive_radius:
			return points[index]

		index += 1

	return fallback


## Whether this path should be recomputed.
##
## Both conditions matter and neither alone is enough: the interval catches a world
## that changed around a stationary goal, and the drift catches a goal that ran.
func needs_repath(now: float, goal: Vector3, interval: float, drift: float) -> bool:
	if is_empty():
		return true

	# A partial path walked to its end is an NPC standing at the near side of something it
	# cannot get through. Searching again at once finds the same partial path, and searching
	# for an unreachable goal is the most expensive question a graph is ever asked — forty
	# zombies piled against a shut gate were each asking it every tick, which was most of a
	# second of server time a second (game-zombie-zone). It waits for the interval, or for the
	# goal to move, like any other path.
	if is_finished() and not partial:
		return true

	if interval > 0.0 and now - computed_at >= interval:
		return true

	return drift > 0.0 and goal.distance_to(goal_at_compute) > drift


## How far is left to walk, following the waypoints rather than the straight line.
func remaining_length(position: Vector3) -> float:
	if is_finished():
		return 0.0

	var total := position.distance_to(points[index])

	for i in range(index, points.size() - 1):
		total += points[i].distance_to(points[i + 1])

	return total


## Whether this path reaches what it was asked for.
func reaches_goal() -> bool:
	return not is_empty() and not partial


func clear() -> void:
	points = PackedVector3Array()
	index = 0


func describe() -> Dictionary:
	return {
		"points": points.size(),
		"at": index,
		"finished": is_finished(),
	}
