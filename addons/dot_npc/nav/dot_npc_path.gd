class_name DotNpcPath
extends RefCounted

## A path being walked: the waypoints, where along them the NPC is, and when to repath.
## Separate from [DotNpcNavGraph]: searching is rare and expensive, following is three subtractions per tick.
## Advancing is a horizontal distance test: a 3D test that works on the flat never fires on a ramp.

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
## The repath trigger that matters: a timer alone is too slow for a runner or too costly for ninety NPCs.
var goal_at_compute: Vector3 = Vector3.ZERO

## Whether the points stop short of the goal because it could not be reached.
## Set by the producer (the spawner copies [member DotNpcNavGraph.last_partial]) so a brain does not
## repath to an unreachable target for ever. Following a partial path is correct; believing it reaches the goal is not.
var partial: bool = false


## Until when (the spawner's clock) this follower's paths come unsmoothed. See [method go_rough].
var rough_until: float = -INF


## Drops the path and asks for the graph's own corners, unsmoothed, for [param seconds].
## For a follower stuck on a corner smoothing cut: a coarse graph says yes to a line that clips a door jamb.
## While rough, a waypoint counts as reached only within [constant ROUGH_ARRIVE] metres.
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
		# Cleared here, not by the caller: set_points is the only way new points arrive, and a
		# surviving flag would describe the previous path.
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
## The interval catches a world that changed around a stationary goal, the drift a goal that ran.
func needs_repath(now: float, goal: Vector3, interval: float, drift: float) -> bool:
	if is_empty():
		return true

		# A partial path walked to its end finds the same partial path again, and searching for an
		# unreachable goal is the costliest query: forty zombies at a shut gate asked it every tick.
		# It waits for the interval or for the goal to move, like any other path.
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
