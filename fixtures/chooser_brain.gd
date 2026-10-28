extends "res://addons/dot_npc/runtime/dot_npc_brain.gd"

## A brain for the self-test that makes its choices the moment it is bound, from its seed.
## Like a real brain with [member DotNpcInstance.seed]: drawn in [method _npc_ready], the earliest a brain can choose.

var first_choices: Array[int] = []


func _npc_ready() -> void:
	var stream := DotRandomStream.new(npc.seed).stream(&"choices")

	for i in 4:
		first_choices.append(stream.range_i_at(i, 0, 999))
