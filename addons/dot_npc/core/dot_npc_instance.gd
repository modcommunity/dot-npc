class_name DotNpcInstance
extends RefCounted

## One NPC in the world: its definition, its node, its health and what it is chasing.
##
## [b]The state is kept here and not on the node[/b], for [DotPropInstance]'s reason:
## metadata on a node is invisible to anything that did not put it there and
## unreachable once the node is freed — and the one moment an NPC's state matters most
## is the tick it dies on, which is the tick its node goes away.

var def: DotNpcDef = null

## The node in the world. May be freed; check with [method is_alive].
var node: Node3D = null

## Godot's instance id for [member node]. The handle everything else uses.
##
## An id rather than the node itself, because a director holding a reference across
## ticks needs a handle that is safe to compare and safe to hold after the node is
## freed. A freed Node compared with `==` is undefined; an int is an int.
var instance_id: int = 0

## Who asked for it: a player id, a director's id, or empty for the map.
var owner_id: StringName = &""

## Simulated seconds when it was spawned. Never a wall clock.
var spawned_at: float = 0.0

## Whether the spawner still considers this NPC to exist.
##
## [b]Separate from the node being valid, and it has to be.[/b] `queue_free()` is
## deferred, so `is_instance_valid` stays true for the rest of the frame after an NPC
## is removed — and a director that checked only the node would keep counting a
## reclaimed NPC against its budget for as long as that frame lasts.
var alive: bool = true

var health: float = 0.0

## What it has committed to, or empty. See [DotNpcSenses] for why it commits.
var target_id: StringName = &""

## Simulated seconds when [member target_id] was last actually perceived.
##
## Not when it was acquired: an NPC keeps chasing through a doorway for
## [member DotNpcSenses.commitment_grace] seconds after it stops seeing anybody, and
## that is measured from the last sighting.
var target_seen_at: float = 0.0

## Simulated seconds when anything last perceived it or it last had a target.
##
## What [member DotNpcLimits.reclaim_grace] is measured from.
var engaged_at: float = 0.0

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


func position() -> Vector3:
	return node.global_position if is_alive() else Vector3.ZERO


## Where it is looking. -Z, Godot's forward, in world space.
func facing() -> Vector3:
	if not is_alive():
		return Vector3.FORWARD
	return -node.global_transform.basis.z.normalized()


func describe() -> Dictionary:
	return {
		"npc": String(def.id) if def != null else "?",
		"owner": String(owner_id),
		"alive": is_alive(),
		"health": "%.0f/%.0f" % [health, def.max_health if def != null else 0.0],
		"target": String(target_id) if has_target() else "-",
	}


func _to_string() -> String:
	return "DotNpcInstance(%s hp %.0f)" % [
		String(def.id) if def != null else "?", health
	]
