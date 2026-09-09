class_name DotNpcNetSync
extends RefCounted

## What an NPC has to tell every client, and how to get it there.
##
## [b]dot-net is not a dependency and is not imported here.[/b] Only dot-core is a hard
## dependency in this family, and a script that [i]mentions[/i] a [code]class_name[/code]
## the project does not have fails to parse — taking every script that references it
## down with it. Types are named as strings and a bridge resolves them with
## [code]DotNetVar.Type[spec.type][/code], exactly as [code]DotMatchNetSync[/code] and
## [code]DotCombatNetSync[/code] do.
##
## [b]Everything here is interpolated and nothing is predicted.[/b] An NPC's position
## comes out of a pathfinder, a steering pass and — for a rigid body — a solver, none of
## which is reproducible across machines, so a client that predicted one would be
## corrected every snapshot. It receives, it interpolates, it draws. That costs the
## rendering a snapshot's worth of lag and buys a horde that does not jitter.
##
## [codeblock]
## class_name ZombieNet extends DotNetBehaviour
##
## var net_x: float
## var net_y: float
## var net_z: float
## var net_yaw: float
## var net_health: int
## var net_state: int
##
## func _register_net_vars() -> void:
##     for spec in DotNpcNetSync.specs():
##         var declaration := replicate(spec.property, DotNetVar.Type[spec.type])
##         if spec.bits > 0:
##             declaration.bits(spec.bits)
##         if spec.interpolated:
##             declaration.interpolated()
## [/codeblock]
##
## [b]Health is a percentage, not the number.[/b] A client draws a health bar and
## nothing else; sending the real figure costs bits per NPC per snapshot for a
## precision no player can see, and at ninety NPCs that is the difference between a
## snapshot that fits in a packet and one that does not.

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


static func specs() -> Array[Dictionary]:
	return [
		# Position as three floats rather than a packed vector, because dot-net
		# quantises per property and a game's world extent is its own: an arena 128 m
		# across and one 4 km across want different bit counts, and one packed type
		# would force the larger on both. The bridge sets the range; this says what
		# the fields are.
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
##
## [param state] is the game's, not this addon's: dot-npc does not know whether an NPC
## is mid-swing, because attacking is [code]dot-npc-ai[/code]'s business or the game's.
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
##
## [b]Never call this on an NPC this peer is the authority for.[/b] The rule
## `_net_state_applied` broke three times in this family: writing a received position
## onto something the local machine is simulating makes the measured correction the
## whole replay distance. NPCs are not predicted, so on a client every NPC is a mirror
## and this is always right there — which is exactly why it is worth saying, because
## the one machine where it is wrong is the server, and a bridge that ran one code path
## for both would do it.
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

	return fposmod(atan2(facing.x, facing.z), TAU)


static func quantise_yaw(yaw: float) -> int:
	var steps := 1 << YAW_BITS

	# `fposmod` before the multiply, because a yaw of exactly TAU would otherwise
	# quantise to `steps` — one past the largest value the field can hold, which
	# dot-net's writer would truncate to 0 and put a body facing backwards once per
	# turn. A wrap that only fires at one angle is the kind nobody reproduces.
	return int(fposmod(yaw, TAU) / TAU * float(steps)) % steps


static func dequantise_yaw(value: int) -> float:
	return float(value) / float(1 << YAW_BITS) * TAU


## Health as 0-100, rounded up so a live NPC never reads as 0.
##
## [b]Up rather than to nearest, and it matters.[/b] An NPC on 0.4% of its health is
## alive, and a client drawing "0" over something that is still swinging at a player is
## a client telling them a lie they will act on.
static func quantise_health(npc: DotNpcInstance) -> int:
	if npc == null or npc.def == null or npc.def.max_health <= 0.0:
		return 0

	if npc.health <= 0.0:
		return 0

	return clampi(int(ceil(npc.health / npc.def.max_health * 100.0)), 1, 100)
