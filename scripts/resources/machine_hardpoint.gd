class_name MachineHardpoint
extends Resource
## One place on a chassis where a part can be bolted.
##
## A hardpoint is the vocabulary of customisation: it says what KIND of part
## belongs here and how big a part the frame can carry there. A chassis is
## therefore nothing more than a body with a list of these, which is what lets
## the same frame become an artillery piece, a brawler or a spotter without a
## single new script.

## What belongs in this slot. A part only fits a hardpoint of its own kind.
enum Slot {
	WEAPON,    ## guns, launchers, melee arms
	ARMOUR,    ## plating and shielding
	MOBILITY,  ## legs, treads, thrusters
	SENSOR,    ## radar dishes, spotters
	UTILITY,   ## salvage claws, repair rigs
}

## How much frame the slot has. A part fits if its own size is no larger.
enum Size { LIGHT, MEDIUM, HEAVY }

@export var id: StringName = &""
@export var slot: Slot = Slot.WEAPON
## Largest part this hardpoint accepts. HEAVY accepts everything.
@export var max_size: Size = Size.MEDIUM
## Node in the chassis glTF to parent the part's model to. Empty means the part
## is fitted internally and shows nothing.
@export var socket: String = ""
## Rotate this hardpoint's model toward the target when the part can aim.
@export var aims: bool = false
