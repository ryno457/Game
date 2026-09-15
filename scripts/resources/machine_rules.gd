class_name MachineRules
extends Resource
## Global rules every machine obeys. Lives in a .tres because these are the
## knobs that decide whether armour is worth its mass and whether overloading a
## frame is ever a good idea.

@export_group("Armour")
## Armour this high halves incoming damage. Lower makes plating stronger.
@export var armour_softening: float = 40.0
## However much armour is stacked, this much damage always gets through.
@export_range(0.0, 1.0) var max_damage_reduction: float = 0.75

@export_group("Overloading")
## Slowest a machine gets from carrying more than its frame's part capacity.
@export_range(0.1, 1.0) var min_speed_fraction: float = 0.4
## How hard overloading bites. 1.0 means speed falls in direct proportion to
## how far over capacity the machine is.
@export_range(0.0, 4.0) var overload_bite: float = 1.0

@export_group("Melee")
## Contact range is not a per-weapon number — every melee part uses this so a
## brawler's reach reads the same whatever it is holding.
@export var melee_reach_m: float = 1.6
