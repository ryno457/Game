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
	## A held beam. Damage is PER SECOND, not per shot, and it ramps the longer
	## it stays on one target — so a laser is strong against a few big things
	## and weak against a swarm, which is exactly the opposite of RANGED. That
	## opposition is the whole reason the family exists: another single-target
	## gun with different numbers would not be a decision.
	BEAM,
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

@export_group("Beam")
## Seconds of unbroken fire to reach full damage on ONE target. Switching
## targets throws it away, which is what makes a beam a commitment.
@export var beam_ramp_s: float = 1.2
## Fraction of `damage` the beam does the instant it touches something. Low
## enough that flicking between targets is genuinely bad; high enough that a
## beam is not useless in its first half-second.
@export_range(0.0, 1.0) var beam_floor: float = 0.3

@export_group("Body")
## A regenerating layer that soaks damage before the hull does, and comes back
## by itself after a few quiet seconds. Fits the ARMOUR slot, which the
## hardpoint enum already calls "plating and shielding".
##
## WHY IT IS NOT JUST MORE HIT POINTS. Plating is permanent and passive: it
## reduces every bite forever. A shield is a budget that refills, so it rewards
## pulling a machine OUT of a fight and punishes leaving it in one — the same
## machine is worth more to a player who manoeuvres. The regen rate and the
## delay live in MachineRules, because they are the balance levers and they
## should be the same for every shield in the game.
@export var shield_add: float = 0.0
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
