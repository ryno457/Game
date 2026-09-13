class_name ChassisConfig
extends Resource
## The Sentinel itself. Module effects live in ModuleDef, not here.

@export var max_hp: float = 600.0
@export var speed_mps: float = 2.875
@export var radius_m: float = 1.625
@export var arrive_threshold_m: float = 0.5
@export var module_bays: int = 6
## Modules seated at mission start when nothing carries forward.
@export var default_loadout: Array[StringName] = []
@export var starting_salvage: int = 60
