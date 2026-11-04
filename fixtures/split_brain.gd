extends "res://addons/dot_npc/runtime/dot_npc_brain.gd"

## A brain for the self-test that thinks as gather, decide, apply: steers at the nearest of three fixed beacons
## and weaves by a hash of (seed, tick), so a run's whole intent history can be hashed.

const BEACONS: Array[Vector3] = [Vector3(10, 0, 0), Vector3(-6, 0, 9), Vector3(0, 0, -12)]

var ticks: int = 0
var history: int = 17


func splits_think() -> bool:
	return true


func is_thread_safe() -> bool:
	return true


func _npc_gather(delta: float) -> Variant:
	return {"pos": npc.position(), "seed": npc.seed, "tick": ticks, "delta": delta}


func _npc_decide(data: Variant) -> Variant:
	var pos: Vector3 = data["pos"]
	var best := BEACONS[0]
	for b in BEACONS:
		if pos.distance_squared_to(b) < pos.distance_squared_to(best):
			best = b
	var weave := float(hash([data["seed"], data["tick"]]) % 100) / 100.0
	var dir := (best - pos).normalized().rotated(Vector3.UP, (weave - 0.5) * 0.8)
	return {"dir": dir, "speed": 2.0 + weave}


func _npc_apply(intent: Variant) -> void:
	ticks += 1
	var d: Vector3 = intent["dir"]
	var v: float = intent["speed"]
	history = hash([history, snappedf(d.x, 0.0001), snappedf(d.z, 0.0001), snappedf(v, 0.0001)])
	npc.node.global_position += d * v * 0.016
