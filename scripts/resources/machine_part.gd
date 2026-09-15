class_name MachinePart
extends Resource
## One bolt-on piece of a machine.
##
## Parts carry every number that makes one machine different from another.
## Nothing here is special-cased in code: a mortar is a part whose family is
## ARTILLERY and whose min_range_m is not zero, and that is the whole of what
## makes artillery artillery.

## How a weapon reaches its target. NONE means this part is not a weapon.
enum Family {
	NONE,
	MELEE,      ## contact range, high damage, no minimum
	RANGED,     ## direct fire, medium range, straight line
	ARTILLERY,  ## indirect, long range, has a minimum range and splash
}

@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""

@export_group("Fit")
@export var slot: MachineHardpoint.Slot = MachineHardpoint.Slot.WEAPON
@export var size: MachineHardpoint.Size = MachineHardpoint.Size.MEDIUM
## Mass this part costs to build and returns when recovered. Mass is conserved,
## so this is body relocated out of the module, never spent.
@export var mass: float = 4.0

@export_group("Weapon")
@export var family: Family = Family.NONE
@export var damage: float = 0.0
@export var range_m: float = 0.0
## Artillery cannot hit what is too close. Zero for everything else.
@export var min_range_m: float = 0.0
@export var cooldown_s: float = 1.0
## Radius of the damage falloff around the hit. Zero is a single target.
@export var splash_m: float = 0.0

@export_group("Body")
@export var hp_add: float = 0.0
## Flat armour. Turned into damage reduction by MachineRules, not by this file.
@export var armour_add: float = 0.0
@export var speed_add_mps: float = 0.0
@export var speed_mult: float = 1.0
## Fog this part sees through on its own.
@export var reveal_m: float = 0.0

@export_group("Presentation")
## glTF in res://models/, without extension. Empty shows nothing.
@export var model: String = ""
@export var colour: Color = Color(0.72, 0.78, 0.84)


func is_weapon() -> bool:
	return family != Family.NONE and damage > 0.0
