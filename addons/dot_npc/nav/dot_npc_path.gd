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


func set_points(p_points: PackedVector3Array, now: float, goal: Vector3) -> void:
	points = p_points
	index = 1 if p_points.size() > 1 else 0
	computed_at = now
	goal_at_compute = goal


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
	if is_empty() or is_finished():
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


func clear() -> void:
	points = PackedVector3Array()
	index = 0


func describe() -> Dictionary:
	return {
		"points": points.size(),
		"at": index,
		"finished": is_finished(),
	}
