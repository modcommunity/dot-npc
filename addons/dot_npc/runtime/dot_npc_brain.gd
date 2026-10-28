class_name DotNpcBrain
extends RefCounted

## What one NPC decides, one tick at a time; the class a game's NPC script extends. Server only.
## A [RefCounted] beside the node, so one scene serves many entries. A delivered brain extends this by path
## (`extends "res://addons/dot_npc/runtime/dot_npc_brain.gd"`), never class_name, which a mounted pack cannot resolve.

## The NPC this brain drives. Set before [method _npc_ready].
var npc: DotNpcInstance = null

## Who is running it. The way to reach the world, the senses and the navigation.
var director: Node = null

## Simulated seconds since this brain was attached. Never a wall clock: an NPC that
## thought in wall time would move at a different speed on a server under load.
var age: float = 0.0

## The path being walked, if this brain paths at all.
var path: DotNpcPath = null



func bind(p_npc: DotNpcInstance, p_director: Node) -> void:
	npc = p_npc
	director = p_director
	path = DotNpcPath.new()
	_npc_ready()


## Lets go of the NPC, the director and anything a subclass built around them.
## A brain and its NPC point at each other and two [RefCounted]s that do are never freed (no cycle
## collector), so [DotNpcSpawner] calls this on removal and again for everything alive when it is freed.
func unbind() -> void:
	_npc_unbound()
	npc = null
	director = null
	path = null


## One simulated tick.
func think(delta: float) -> void:
	age += delta
	_npc_think(delta)


func damaged(amount: float, by: StringName) -> void:
	_npc_damaged(amount, by)


func died(by: StringName) -> void:
	_npc_died(by)



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


## Called by [method unbind], before [member npc] is cleared. Drop every reference that
## leads back to this brain or to its NPC — a context, a tree, a state machine — or the
## cycle outlives the spawner that made it.
func _npc_unbound() -> void:
	pass



## A tuning number from the definition's [code]meta[/code], or [param fallback].
## Tuning lives in the catalogue so one script serves several entries and an operator can reach it.
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
## Asked of the director, not cached: a brain that cached a player's position would chase where they were.
func target_position(fallback: Vector3 = Vector3.ZERO) -> Vector3:
	if director == null or npc == null or not npc.has_target():
		return fallback

	if not director.has_method(&"candidate_position"):
		return fallback

	var found: Variant = director.call(&"candidate_position", npc.target_id)

	return found if found is Vector3 else fallback


## Steers toward [param to], pathing around the level when there is navigation data.
## Falls back to steering straight at the goal when there is no path, on purpose: standing still
## because the generator missed a corner is a bug nobody can see the cause of.
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
## Works on a [CharacterBody3D], a [RigidBody3D] or a plain [Node3D]: the body is the definition's scene.
func steer_toward(to: Vector3, speed: float, delta: float) -> void:
	if npc == null or not npc.is_alive():
		return

	var direction := to - npc.position()
	direction.y = 0.0

	if direction.length() < 0.001:
		return

	direction = direction.normalized()

	# A 2D body. The plane is XZ — see [member DotNpcInstance.node] — so a direction's
	# `z` is the 2D `y`, and nothing else about this function applies: there is no
	# gravity to add, no floor to be on, and no basis to rotate.
	if npc.node is Node2D:
		var flat := DotNpcInstance.from_plane(direction)
		var body_2d := npc.node as Node2D

		if body_2d is RigidBody2D:
			(body_2d as RigidBody2D).linear_velocity = flat * speed
		elif body_2d is CharacterBody2D:
			var character_2d := body_2d as CharacterBody2D
			character_2d.velocity = flat * speed
			character_2d.move_and_slide()
		else:
			body_2d.global_position += flat * speed * delta

		body_2d.global_rotation = flat.angle()
		return

	var body := npc.node as Node3D

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
				# Only the horizontal is written: overwriting `y` on a rigid body cancels gravity and every
				# impulse, so an NPC could not be knocked about.
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

	if npc.node is Node2D:
		(npc.node as Node2D).global_rotation = DotNpcInstance.from_plane(flat).angle()
		return

	var body := npc.node as Node3D
		# `look_at` errors on a target equal to the node's position, so the flat length check keeps that off the log
		# (and a body fallen out of the map). Look at `position + direction`: -Z is what [method DotNpcInstance.facing]
		# reads, and `- direction` pointed the sight cone behind a chasing monster.
	var origin := body.global_position
	var target := origin + flat.normalized()

	if not origin.is_finite() or target.is_equal_approx(origin):
		return

	body.look_at(target, Vector3.UP)


## Stops the body dead, horizontally.
func halt() -> void:
	if npc == null or not npc.is_alive():
		return

	var body := npc.node

	if body is RigidBody2D:
		(body as RigidBody2D).linear_velocity = Vector2.ZERO
	elif body is CharacterBody2D:
		(body as CharacterBody2D).velocity = Vector2.ZERO
	elif body is CharacterBody3D:
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
