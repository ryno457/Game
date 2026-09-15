class_name MachineChassis
extends Resource
## A bare frame: a body with hardpoints and nothing fitted to them.
##
## The frame decides how much a machine can carry and where; the parts decide
## what it does. Fielding an artillery army versus a melee one is a question of
## which parts go into which frames, not of which frames exist.

@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""

@export_group("Body")
## Mass of the frame itself, before anything is bolted on.
@export var base_mass: float = 6.0
@export var base_hp: float = 60.0
@export var base_armour: float = 0.0
@export var base_speed_mps: float = 4.0
@export var radius_m: float = 0.55

@export_group("Carry")
## Mass of PARTS the frame carries without complaint. Going over does not fail
## the build — it slows the machine down, so overloading is a choice with a
## price rather than a wall.
@export var part_capacity: float = 10.0

@export_group("Convoy")
@export var escort_radius_m: float = 6.0
@export var escort_speed_mps: float = 8.0

@export_group("Presentation")
@export var model: String = ""
@export var colour: Color = Color(0.31, 0.89, 0.76)

@export_group("Hardpoints")
@export var hardpoints: Array[MachineHardpoint] = []


func hardpoint(index: int) -> MachineHardpoint:
	return hardpoints[index] if index >= 0 and index < hardpoints.size() else null
