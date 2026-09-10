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
##
## [b]Typed [Node] rather than [Node3D], because an NPC is not always a 3D one.[/b] The
## catalogue, the population budget, the per-kind cap, the perception, the commitment and
## the reclaim are all about behaviour rather than about dimension, and a 2D game that had
## to re-implement them would be re-implementing the addon to avoid a `Vector3`.
##
## [b]A 2D world is the XZ plane, and y is always zero.[/b] That is the whole of the
## mapping and it is what lets everything above stay unchanged: [DotNpcSenses] compares
## 3D distances, [DotNpcAiSteering] returns 3D directions, and [DotNpcNavData] is a graph
## of 3D points — all of which are exactly right on a plane where one component never
## moves. [method position] answers in that plane for a [Node2D] as well as a [Node3D], so
## nothing downstream has to know which it is looking at; [method position_2d] converts
## back for a caller that is drawing.
var node: Node = null

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
##
## [b]This moves on EVERY pass in which the target is perceived, and that is what it is
## for.[/b] It answers "is this NPC still busy" — which is the question a reclaim asks —
## and it is deliberately NOT the answer to "how long has it known about this one". See
## [member target_since], which exists because dot-npc-ai measured a reaction time against
## this field and therefore never finished reacting.
var engaged_at: float = 0.0

## Simulated seconds when this NPC committed to its CURRENT target.
##
## [b]Set when [member target_id] CHANGES, and not while it is held.[/b] That is the whole
## difference from [member engaged_at], and it is a real one: a reaction time measured
## against a field that is refreshed every tick can never elapse, so every branch behind
## such a gate never runs — and a bot that never acts on what it sees looks like a bot that
## is bad rather than like one that is broken.
##
## dot-npc-ai's `has_reacted()` used `engaged_at` and was therefore always false for any
## NPC that could currently see its target, which is every NPC that would ever act on one.
## Found by game-playground putting a `DotNpcAiBrain` behind dot-npc's senses and watching
## a hunter sit in ALERT for ever.
var target_since: float = 0.0

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
	if not is_alive():
		return Vector3.ZERO

	if node is Node3D:
		return (node as Node3D).global_position

	if node is Node2D:
		return to_plane((node as Node2D).global_position)

	return Vector3.ZERO


## Where it is, for a 2D game. Zero for a 3D one.
func position_2d() -> Vector2:
	if not is_alive() or not (node is Node2D):
		return Vector2.ZERO

	return (node as Node2D).global_position


## Whether this NPC lives in a 2D world.
##
## Asked rather than inferred: a [DotNpcDef] deliberately says nothing about dimension,
## and a host with a 2D world and a 3D preview is a legitimate thing to be.
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
	if not is_alive():
		return Vector3.FORWARD

	if node is Node3D:
		return -(node as Node3D).global_transform.basis.z.normalized()

	if node is Node2D:
		# A Node2D's rotation is around the screen normal, and this addon's plane puts
		# that screen on XZ — so a 2D heading of `rotation` is `(cos, 0, sin)`, and
		# forward is that rather than -Z. Getting the axis wrong here is an NPC that
		# perceives things behind it, which is a sight cone that appears not to work.
		var angle := (node as Node2D).global_rotation
		return Vector3(cos(angle), 0.0, sin(angle))

	return Vector3.FORWARD


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
