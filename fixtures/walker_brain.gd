extends "res://addons/dot_npc/runtime/dot_npc_brain.gd"

## A brain for the self-test: walks at whatever it has committed to, and counts.
##
## [b]Extends a PATH, not [code]DotNpcBrain[/code], and the suite asserts that this
## file loads.[/b] It is the shape a brain delivered inside a mounted dot-cloud pack
## must have — a `.pck` arrives long after the project's script cache was built, so a
## `class_name` in it resolves to nothing. Writing the fixture the wrong way would
## make the suite pass for a shape the addon does not actually support.

var thinks: int = 0
var deaths: int = 0
var damage_taken: float = 0.0


func _npc_think(delta: float) -> void:
	thinks += 1

	if not npc.has_target():
		halt()
		return

	steer_along_path(target_position(), tune(&"speed", 4.0), delta)


func _npc_damaged(amount: float, _by: StringName) -> void:
	damage_taken += amount


func _npc_died(_by: StringName) -> void:
	deaths += 1
