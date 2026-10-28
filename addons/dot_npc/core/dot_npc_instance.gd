class_name DotNpcInstance
extends RefCounted

## One NPC in the world: its definition, its node, its health and what it is chasing.
## State lives here, not on the node: it must outlive the node, and the tick an NPC dies
## on is the tick its node goes away.

var def: DotNpcDef = null

## The node in the world. May be freed; check with [method is_alive].
## Typed [Node], not [Node3D], so a 2D game reuses the budget and senses; a 2D world is the XZ plane, y zero.
## [method position] answers in that plane, [method position_2d] converts back for drawing.
var node: Node = null

## Godot's instance id for [member node]: a handle safe to compare and hold after the node is freed.
## An identity, never a seed: it depends on how many objects the process created first, so
## a replay would disagree. Seed choices from [member seed].
var instance_id: int = 0

## This NPC's own random seed: the same number for the same spawn in every run.
## Set by [DotNpcSpawner] before the brain is bound. Always above 1, because dot-npc-ai reads 0 or 1
## as "still the preset's". Zero means built by hand. Not [member instance_id], which moves with unrelated objects.
var seed: int = 0

## Who asked for it: a player id, a director's id, or empty for the map.
var owner_id: StringName = &""

## Simulated seconds when it was spawned. Never a wall clock.
var spawned_at: float = 0.0

## Whether the spawner still considers this NPC to exist.
## Separate from the node being valid: `queue_free()` is deferred, so a reclaimed NPC would
## keep counting against the budget for the rest of the frame.
var alive: bool = true

var health: float = 0.0

## What it has committed to, or empty. See [DotNpcSenses] for why it commits.
var target_id: StringName = &""

## Simulated seconds when [member target_id] was last actually perceived.
## Not when acquired: the commitment grace ([member DotNpcSenses.commitment_grace]) runs from the last sighting.
var target_seen_at: float = 0.0

## Simulated seconds when anything last perceived it or it last had a target.
## What [member DotNpcLimits.reclaim_grace] is measured from. Moves every pass the target is
## perceived; not a reaction timer, see [member target_since].
var engaged_at: float = 0.0

## Simulated seconds when this NPC committed to its CURRENT target.
## Set when [member target_id] changes, not while held: a reaction time measured against
## [member engaged_at], refreshed every tick, can never elapse.
var target_since: float = 0.0

## Multiplies the definition's sight range for this one NPC. 1.0 is "as the kind says".
## Per instance: a kind's range and one NPC's attentiveness differ. Sight only; hearing is a measured loudness.
var sight_scale: float = 1.0

## The last perception pass found nothing within reach (see [member DotNpcLimits.sense_quiet_mult]).
var sense_quiet: bool = false

## The brain, if the definition named one. Never a `class_name`.
var brain: Object = null

## Anything the game keeps with an NPC.
var meta: Dictionary = {}


func is_alive() -> bool:
	return alive and node != null and is_instance_valid(node)


func has_target() -> bool:
	return target_id != &""


func health_fraction() -> float:
	if def == null or def.max_health <= 0.0:
		return 0.0
	return clampf(health / def.max_health, 0.0, 1.0)


## Where it is, in the 3D plane everything in this addon measures in.
##
## A [Node2D] at `(x, y)` answers `Vector3(x, 0, y)`. See the note on [member node].
func position() -> Vector3:
	# is_alive() inlined: a horde asks this hundreds of times a tick.
	if not alive or node == null or not is_instance_valid(node):
		return Vector3.ZERO

	var body := node as Node3D
	if body != null:
		return body.global_position

	if node is Node2D:
		return to_plane((node as Node2D).global_position)

	return Vector3.ZERO


## Where it is, for a 2D game. Zero for a 3D one.
func position_2d() -> Vector2:
	if not is_alive() or not (node is Node2D):
		return Vector2.ZERO

	return (node as Node2D).global_position


## Whether this NPC lives in a 2D world.
## Asked, not inferred: a [DotNpcDef] says nothing about dimension.
func is_2d() -> bool:
	return node is Node2D


## A 2D point in the plane this addon measures in.
static func to_plane(at: Vector2) -> Vector3:
	return Vector3(at.x, 0.0, at.y)


## The reverse. Drops the vertical, which on a 2D world is always zero anyway.
static func from_plane(at: Vector3) -> Vector2:
	return Vector2(at.x, at.z)


## Where it is looking. -Z, Godot's forward, in world space.
func facing() -> Vector3:
	if not alive or node == null or not is_instance_valid(node):
		return Vector3.FORWARD

	var body := node as Node3D
	if body != null:
		return -body.global_transform.basis.z.normalized()

	if node is Node2D:
		# A Node2D rotates around the screen normal and 2D here is the XZ plane, so heading is
		# `(cos, 0, sin)` rather than -Z; the wrong axis gives a sight cone that seems not to work.
		var angle := (node as Node2D).global_rotation
		return Vector3(cos(angle), 0.0, sin(angle))

	return Vector3.FORWARD


func describe() -> Dictionary:
	return {
		"npc": String(def.id) if def != null else "?",
		"owner": String(owner_id),
		"seed": seed,
		"alive": is_alive(),
		"health": "%.0f/%.0f" % [health, def.max_health if def != null else 0.0],
		"target": String(target_id) if has_target() else "-",
	}


func _to_string() -> String:
	return "DotNpcInstance(%s hp %.0f)" % [
		String(def.id) if def != null else "?", health
	]
