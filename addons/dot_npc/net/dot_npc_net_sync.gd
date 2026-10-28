class_name DotNpcNetSync
extends RefCounted

## What an NPC has to tell every client, and how to get it there.
## dot-net is not imported (a script naming a missing class_name fails to parse): types are strings a bridge
## resolves with `DotNetVar.Type[spec.type]`. All interpolated, nothing predicted. Health is a percentage.

## Health as 0-100. Seven bits, because a client only ever draws a bar with it.
const HEALTH_BITS := 7

## Yaw quantised over a full turn. Nine bits is 0.7 degrees, which is under the angle
## a player can tell apart on a body thirty metres away.
const YAW_BITS := 9

## The behaviour state a client needs in order to pick an animation.
const STATE_BITS := 4

## What a client does with an NPC. Deliberately small and deliberately about
## APPEARANCE rather than about decisions: a client picks an animation with this, and
## a client that knew an NPC was "flanking" would be a client that could be read.
enum State {
	IDLE,
	MOVING,
	ATTACKING,
	HURT,
	DEAD,
}


## One bit per limb ([constant DotNpcLimbs.MAX_LIMBS]): set when it has been severed.
const LIMB_BITS := 8


## The one extra field of an NPC with [DotNpcLimbs]: `net_limbs`, filled from `DotNpcLimbs.mask()` and applied
## with `apply_mask()`. Kept out of [method specs] so a game without limbs declares nothing new.
static func limb_specs() -> Array[Dictionary]:
	return [{"property": &"net_limbs", "type": "UINT", "bits": LIMB_BITS, "interpolated": false}]


static func specs() -> Array[Dictionary]:
	return [
				# Position as three floats, not a packed vector: dot-net quantises per property and a game's
				# world extent is its own, so one packed type would force the larger bit count on both.
				# The bridge sets the range.
		{"property": &"net_x", "type": "FLOAT", "bits": 0, "interpolated": true},
		{"property": &"net_y", "type": "FLOAT", "bits": 0, "interpolated": true},
		{"property": &"net_z", "type": "FLOAT", "bits": 0, "interpolated": true},
		{"property": &"net_yaw", "type": "UINT", "bits": YAW_BITS, "interpolated": true},
		{
			"property": &"net_health",
			"type": "UINT",
			"bits": HEALTH_BITS,
			"interpolated": false,
		},
		{
			"property": &"net_state",
			"type": "UINT",
			"bits": STATE_BITS,
			"interpolated": false,
		},
	]


static func properties() -> Array[StringName]:
	var out: Array[StringName] = []

	for spec in specs():
		out.append(spec["property"])

	return out


## Copies an NPC's state onto a replicating object.
## [param state] is the game's: dot-npc does not know whether an NPC is mid-swing.
static func pull(npc: DotNpcInstance, into: Object, state: int = State.IDLE) -> void:
	if npc == null or into == null:
		return

	var position := npc.position()

	into.set(&"net_x", position.x)
	into.set(&"net_y", position.y)
	into.set(&"net_z", position.z)
	into.set(&"net_yaw", quantise_yaw(yaw_of(npc)))
	into.set(&"net_health", quantise_health(npc))
	into.set(&"net_state", clampi(state, 0, State.size() - 1))


## Writes replicated state onto a mirroring node. The client half of [method pull].
## Never call this on an NPC this peer is the authority for: writing a received position onto
## something simulated locally makes the measured correction the whole replay distance. Right on every client, wrong on the server.
static func apply(node: Node3D, from: Object) -> void:
	if node == null or from == null:
		return

	node.global_position = Vector3(
		float(from.get(&"net_x")),
		float(from.get(&"net_y")),
		float(from.get(&"net_z"))
	)

	node.rotation.y = dequantise_yaw(int(from.get(&"net_yaw")))


## The NPC's facing as a yaw in radians, 0 to TAU.
static func yaw_of(npc: DotNpcInstance) -> float:
	if npc == null or not npc.is_alive():
		return 0.0

	var facing := npc.facing()

		# The node's own `rotation.y`, which [method apply] writes back. Facing is -Z, so a yaw of θ faces
		# (-sin θ, 0, -cos θ) and θ is atan2 of the NEGATED facing; `atan2(facing.x, facing.z)` is half a turn out.
	return fposmod(atan2(-facing.x, -facing.z), TAU)


static func quantise_yaw(yaw: float) -> int:
	var steps := 1 << YAW_BITS

		# `fposmod` before the multiply: a yaw of exactly TAU would quantise to `steps`, one past the
		# field's largest value, which dot-net's writer truncates to 0 and turns the body backwards once per turn.
	return int(fposmod(yaw, TAU) / TAU * float(steps)) % steps


static func dequantise_yaw(value: int) -> float:
	return float(value) / float(1 << YAW_BITS) * TAU


## Health as 0-100, rounded up so a live NPC never reads as 0.
## Up, not to nearest: a client drawing "0" over something still swinging at a player lies to them.
static func quantise_health(npc: DotNpcInstance) -> int:
	if npc == null or npc.def == null or npc.def.max_health <= 0.0:
		return 0

	if npc.health <= 0.0:
		return 0

	return clampi(int(ceil(npc.health / npc.def.max_health * 100.0)), 1, 100)
