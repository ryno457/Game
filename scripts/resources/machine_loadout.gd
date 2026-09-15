class_name MachineLoadout
extends Resource
## A chassis with parts chosen for its hardpoints — one machine the player can
## actually build.
##
## `fitted` lines up with `chassis.hardpoints` by index. A null entry is an
## empty hardpoint, which is legal: a half-kitted frame is cheaper and faster,
## and that is a real choice rather than an error.

@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""
@export var chassis: MachineChassis
@export var fitted: Array[MachinePart] = []


## Part in a named hardpoint, or null.
func part_in(hardpoint_id: StringName) -> MachinePart:
	if chassis == null:
		return null
	for i in chassis.hardpoints.size():
		if chassis.hardpoints[i].id == hardpoint_id:
			return fitted[i] if i < fitted.size() else null
	return null


## Pad or trim `fitted` so it lines up with the chassis. Called by tools and
## editors; the resolver reports a mismatch rather than hiding it.
func normalise() -> void:
	if chassis == null:
		return
	fitted.resize(chassis.hardpoints.size())
