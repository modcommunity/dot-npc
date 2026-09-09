extends RefCounted

## A script that is not a brain. The suite spawns an NPC that names this to prove the
## spawner refuses it rather than calling `think` on something that has no such method
## — which is a crash on the tick after a spawn, in the middle of a round.
