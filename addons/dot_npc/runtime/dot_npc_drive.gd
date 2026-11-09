class_name DotNpcDrive
extends RefCounted

## A player's hands on an NPC body. While [member active], [method DotNpcBrain.think] calls
## [method DotNpcBrain._npc_driven] instead of [method DotNpcBrain._npc_think], so the AI does
## not run and the game moves the body from this intent. Plain numbers, so any input codec
## (a dot-player-controller command, a bot) fills it the same way. Server only.

## Whether a player holds the body.
var active: bool = false

## Who holds it: the game's id for the player (peer, user or slot). Opaque here.
var holder: StringName = &""

## Move intent: x strafes (right positive), y is forward (positive forward), each in -1..1.
var move: Vector2 = Vector2.ZERO

## Where the holder faces, radians about +Y (0 faces -Z, Godot's forward).
var yaw: float = 0.0

## Held buttons, a bit set the game defines (primary attack, jump, ...).
var buttons: int = 0

## Buttons that went down since the game last called [method take_pressed].
var _pressed: int = 0


func grab(p_holder: StringName) -> void:
	active = true
	holder = p_holder
	move = Vector2.ZERO
	buttons = 0
	_pressed = 0


func release() -> void:
	active = false
	holder = &""
	move = Vector2.ZERO
	buttons = 0
	_pressed = 0


## Latest input. A button newly set in [param p_buttons] is remembered as pressed until taken.
func feed(p_move: Vector2, p_yaw: float, p_buttons: int) -> void:
	move = p_move.limit_length(1.0)
	yaw = p_yaw
	_pressed |= p_buttons & ~buttons
	buttons = p_buttons


## The buttons pressed since the last call, then forgotten: an edge, for a swing or a jump.
func take_pressed() -> int:
	var out := _pressed
	_pressed = 0
	return out


## The world-space direction of [member move] for the holder's facing; zero when still.
func direction() -> Vector3:
	return Basis(Vector3.UP, yaw) * Vector3(move.x, 0.0, -move.y)


## [method direction] scaled to [param speed].
func wish_velocity(speed: float) -> Vector3:
	return direction() * speed
