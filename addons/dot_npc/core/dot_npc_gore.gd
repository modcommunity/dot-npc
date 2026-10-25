class_name DotNpcGore
extends RefCounted

## How much dismemberment a process shows and allows, as one process-wide dial (`gore_level`) plus the
## gib cap. A server owner or a family-friendly platform turns it down; no game logic reads anything else.
##
## Static on purpose: gore is a presentation policy, and a listen server and its client are one process.
## The server side of it (whether a limb can come off, how much it takes) is read by [DotNpcLimbs];
## the drawn side (gib bodies, spray, drip) by [DotNpcGibs]. Level 0 is "no dismemberment": every
## limb call is a no-op, so a body behaves as if it had no limbs.

const OFF := 0
## Limbs come off as clean stumps: no flying gib, no spray, no drip.
const STUMPS := 1
## Limbs fly off with a spray and a drip (the default).
const GIBS := 2
## Limbs give way sooner and the spray is heavier.
const SPLATTER := 3

## Largest value of [member level].
const MAX_LEVEL := 3
## The most flying limbs alive at once on this machine; the oldest is recycled for the next.
const DEFAULT_MAX_GIBS := 24

## 0 to 3, see the constants. Clamped on write.
static var level: int = GIBS:
	set(v):
		level = clampi(v, OFF, MAX_LEVEL)
## Live gib bodies allowed. 0 spawns none (stumps and spray remain).
static var max_gibs: int = DEFAULT_MAX_GIBS:
	set(v):
		max_gibs = maxi(v, 0)


## Whether any limb can come off.
static func dismember_enabled() -> bool:
	return level >= STUMPS


## Whether a severed limb is thrown as a body.
static func gibs_enabled() -> bool:
	return level >= GIBS and max_gibs > 0


## Whether the cut sprays and drips blood.
static func spray_enabled() -> bool:
	return level >= GIBS


## Particle count multiplier for blood at the current level.
static func spray_scale() -> float:
	return 2.0 if level >= SPLATTER else 1.0


## Multiplier on the health a limb has: at the top level a limb gives way to less.
static func health_scale() -> float:
	return 0.6 if level >= SPLATTER else 1.0


## Back to the defaults (a suite, or a game unloading).
static func reset() -> void:
	level = GIBS
	max_gibs = DEFAULT_MAX_GIBS
