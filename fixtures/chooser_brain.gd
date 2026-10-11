extends "res://addons/dot_npc/runtime/dot_npc_brain.gd"

## A brain for the self-test that makes its choices the moment it is bound, from its seed.
##
## What a real brain does with [member DotNpcInstance.seed]: an alert delay, a wander
## direction, which of three branches to take. Drawn in [method _npc_ready] because that is
## the earliest a brain can choose, and the seed has to be there by then.

var first_choices: Array[int] = []


func _npc_ready() -> void:
	var stream := DotRandomStream.new(npc.seed).stream(&"choices")

	for i in 4:
		first_choices.append(stream.range_i_at(i, 0, 999))
