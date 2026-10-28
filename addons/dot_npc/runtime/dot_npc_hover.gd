class_name DotNpcHover
extends RefCounted

## A jetpack's flight as a state machine that wants a velocity: lift, cruise, hover, land when fuel is low,
## regain fuel on the ground. Holds no node; the body moves itself at the velocity [method step] returns.
## It does not path: it flies straight at the goal, so a goal across a wall wants the caller to pick a point above it.

enum State { GROUNDED, LIFT, CRUISE, HOVER, LAND, DISABLED }

var state: State = State.GROUNDED
var fuel_max: float = 12.0
var fuel: float = 12.0
var burn_rate: float = 1.0
var regen_rate: float = 1.5
var cruise_height: float = 7.0
var max_speed: float = 9.0
var climb_speed: float = 6.0
var descent_speed: float = 5.0
var acceleration: float = 14.0
## Fuel share needed to take off again after landing.
var relight_share: float = 0.6
## Velocity as last returned, smoothed.
var velocity: Vector3 = Vector3.ZERO


func airborne() -> bool:
	return state == State.LIFT or state == State.CRUISE or state == State.HOVER or state == State.LAND


func disabled() -> bool:
	return state == State.DISABLED


## 0 to 1, for the exhaust: full while climbing, a third while hovering, none on the ground.
func throttle() -> float:
	match state:
		State.LIFT:
			return 1.0
		State.CRUISE:
			return 0.8
		State.HOVER:
			return 0.4
		State.LAND:
			return 0.25
	return 0.0


## Burns out: it never lights again.
func disable() -> void:
	state = State.DISABLED
	velocity = Vector3.ZERO


func refuel() -> void:
	fuel = fuel_max


## One step. [param wants_air] is whether the brain wants to be flying, [param goal] where it
## wants to be, [param ground_y] the height of the floor under [param pos]. Returns the velocity
## to move at (while falling after a disable it returns zero: gravity is the caller's).
func step(delta: float, pos: Vector3, goal: Vector3, ground_y: float, wants_air: bool) -> Vector3:
	if state == State.DISABLED:
		return Vector3.ZERO

	var height := pos.y - ground_y
	var burning := state != State.GROUNDED

	if burning:
		fuel = maxf(fuel - burn_rate * delta, 0.0)
	else:
		fuel = minf(fuel + regen_rate * delta, fuel_max)

	match state:
		State.GROUNDED:
			if wants_air and fuel >= fuel_max * relight_share:
				state = State.LIFT
		State.LIFT:
			if not wants_air or fuel <= 0.0:
				state = State.LAND
			elif height >= cruise_height - 0.5:
				state = State.CRUISE
		State.CRUISE, State.HOVER:
			if not wants_air or fuel <= 0.0:
				state = State.LAND
			else:
				var flat := Vector2(goal.x - pos.x, goal.z - pos.z).length()
				state = State.HOVER if flat < 1.5 else State.CRUISE
		State.LAND:
			if height <= 0.3:
				state = State.GROUNDED
			elif wants_air and fuel > fuel_max * 0.3 and height > 2.0:
				state = State.LIFT

	var want := Vector3.ZERO

	match state:
		State.LIFT:
			want.y = climb_speed
		State.CRUISE, State.HOVER:
			var to := Vector3(goal.x - pos.x, 0.0, goal.z - pos.z)
			var flat := to.length()
			want = to.normalized() * minf(max_speed, flat * 2.0)
			want.y = clampf((cruise_height - height) * 2.0, -descent_speed, climb_speed)
		State.LAND:
			want.y = -descent_speed

	velocity = velocity.move_toward(want, acceleration * delta)
	return velocity
