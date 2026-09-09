class_name DotNpcBrain
extends RefCounted

## What one NPC decides, one tick at a time. The class a game's NPC script extends.
##
## [b]A [RefCounted] beside the node, not a script on it.[/b] The node is the
## definition's scene and belongs to whoever made the art; a brain that had to be the
## scene's root script would mean one scene per behaviour, which is exactly the
## per-map-project mistake [DotNpcDef] exists to avoid. It also means one scene can
## serve a dozen catalogue entries at different speeds, which is the cheap way to
## ship NPCs and the way a sandbox actually does it.
##
## [b]A delivered brain extends this by PATH, never by name.[/b]
##
## [codeblock]
## extends "res://addons/dot_npc/runtime/dot_npc_brain.gd"
##
## func _npc_think(delta: float) -> void:
##     if not npc.has_target():
##         return
##     steer_along_path(target_position(), tune(&"speed", 3.0), delta)
## [/codeblock]
##
## A script inside a mounted dot-cloud pack cannot resolve a [code]class_name[/code] —
## the project's script cache was built long before the pack arrived — so
## [code]extends DotNpcBrain[/code] fails to compile in exactly the deployment this
## addon was shaped for. `extends "res://..."` works in both. game-playground's
## entities already do this and say so.
##
## [b]This runs on the server only.[/b] See [DotNpcDirector] for why NPCs are not
## predicted.

## The NPC this brain drives. Set before [method _npc_ready].
var npc: DotNpcInstance = null

## Who is running it. The way to reach the world, the senses and the navigation.
var director: Node = null

## Simulated seconds since this brain was attached. Never a wall clock: an NPC that
## thought in wall time would move at a different speed on a server under load.
var age: float = 0.0

## The path being walked, if this brain paths at all.
var path: DotNpcPath = null


# --- Called by the director --------------------------------------------------

func bind(p_npc: DotNpcInstance, p_director: Node) -> void:
	npc = p_npc
	director = p_director
	path = DotNpcPath.new()
	_npc_ready()


## One simulated tick.
func think(delta: float) -> void:
	age += delta
	_npc_think(delta)


func damaged(amount: float, by: StringName) -> void:
	_npc_damaged(amount, by)


func died(by: StringName) -> void:
	_npc_died(by)


# --- Subclass interface ------------------------------------------------------

## Called once, after the node is in the world and the instance is registered.
func _npc_ready() -> void:
	pass


## Called every simulated tick while the NPC is alive.
func _npc_think(_delta: float) -> void:
	pass


## Called after health has already been reduced. [param by] may be empty.
func _npc_damaged(_amount: float, _by: StringName) -> void:
	pass


## Called once, before the node is freed. The last chance to drop a loot bag.
func _npc_died(_by: StringName) -> void:
	pass


# --- Helpers for subclasses --------------------------------------------------

## A tuning number from the definition's [code]meta[/code], or [param fallback].
##
## Tuning lives in the catalogue, not in the script, for the reason in the class note:
## it is what lets one script serve several entries, and it is the only half of an NPC
## an operator editing a JSON catalogue can reach.
func tune(key: StringName, fallback: float) -> float:
	if npc == null or npc.def == null:
		return fallback

	var raw: Variant = npc.def.meta.get(String(key), null)

	return float(raw) if raw is float or raw is int else fallback


func tune_string(key: StringName, fallback: String = "") -> String:
	if npc == null or npc.def == null:
		return fallback

	var raw: Variant = npc.def.meta.get(String(key), null)

	return str(raw) if raw != null else fallback


## Where the committed target is, or [param fallback] when there is none.
##
## Asked of the director rather than kept here, because the position of a player is
## the game's fact and a brain that cached one would chase where somebody was.
func target_position(fallback: Vector3 = Vector3.ZERO) -> Vector3:
	if director == null or npc == null or not npc.has_target():
		return fallback

	if not director.has_method(&"candidate_position"):
		return fallback

	var found: Variant = director.call(&"candidate_position", npc.target_id)

	return found if found is Vector3 else fallback


## Steers toward [param to], pathing around the level when there is navigation data.
##
## Falls back to steering straight at the goal when there is no path, which is a
## decision rather than an oversight: an NPC that stood still whenever the navigation
## generator had missed a corner would be a bug nobody could see the cause of, and one
## that walks into a wall is a bug anybody watching can describe.
func steer_along_path(to: Vector3, speed: float, delta: float) -> void:
	if npc == null or not npc.is_alive():
		return

	var goal := to

	if director != null and director.has_method(&"path_toward"):
		var found: Variant = director.call(&"path_toward", npc, path, to)

		if found is Vector3:
			goal = found

	steer_toward(goal, speed, delta)


## Drives the body's horizontal velocity toward [param to] at [param speed].
##
## Works on a [CharacterBody3D], a [RigidBody3D] or a plain [Node3D], because an NPC's
## body is the definition's scene and this addon does not get to choose what that is.
func steer_toward(to: Vector3, speed: float, delta: float) -> void:
	if npc == null or not npc.is_alive():
		return

	var body := npc.node
	var direction := to - body.global_position
	direction.y = 0.0

	if direction.length() < 0.001:
		return

	direction = direction.normalized()

	if body is CharacterBody3D:
		var character := body as CharacterBody3D
		var wanted := direction * speed
		character.velocity.x = wanted.x
		character.velocity.z = wanted.z
		# Gravity is applied here rather than left to the game, because a
		# CharacterBody3D does not have any and an NPC walking off a ledge would
		# otherwise carry on horizontally through the air for ever.
		if not character.is_on_floor():
			character.velocity.y -= 9.8 * delta
		else:
			character.velocity.y = 0.0
		character.move_and_slide()
	elif body is RigidBody3D:
		var rigid := body as RigidBody3D
		var current := rigid.linear_velocity
		var wanted_rigid := direction * speed
		# Only the horizontal is written. Overwriting `y` on a rigid body cancels
		# gravity and every impulse a physics gun or an explosion put into it, which
		# turns an NPC into something that cannot be knocked about — and being able to
		# punt one across the map is the first thing a sandbox player tries.
		rigid.linear_velocity = Vector3(wanted_rigid.x, current.y, wanted_rigid.z)
	else:
		body.global_position += direction * speed * delta

	face(direction)


## Points the body along [param direction], horizontally.
func face(direction: Vector3) -> void:
	if npc == null or not npc.is_alive():
		return

	var flat := Vector3(direction.x, 0.0, direction.z)

	if flat.length() < 0.001:
		return

	var body := npc.node
	# `look_at` refuses a target equal to the node's own position and prints an error;
	# the flat length check above is what keeps that off a server's log once a tick per
	# NPC, which is the sort of thing that turns a log into noise nobody reads.
	body.look_at(body.global_position - flat.normalized(), Vector3.UP)


## Stops the body dead, horizontally.
func halt() -> void:
	if npc == null or not npc.is_alive():
		return

	var body := npc.node

	if body is CharacterBody3D:
		var character := body as CharacterBody3D
		character.velocity.x = 0.0
		character.velocity.z = 0.0
	elif body is RigidBody3D:
		var rigid := body as RigidBody3D
		rigid.linear_velocity = Vector3(0.0, rigid.linear_velocity.y, 0.0)


func describe() -> Dictionary:
	return {
		"brain": get_script().resource_path.get_file() if get_script() != null else "?",
		"age": "%.1f" % age,
		"path": path.describe() if path != null else {},
	}
