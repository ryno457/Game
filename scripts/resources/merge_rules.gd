class_name MergeRules
extends Resource
## Rules for reforging machines in the field.
##
## A machine is mass in a shape. Changing the shape is always allowed — what it
## costs is the same thing everything else in this economy costs: time, plus
## the machines being out of the line while it happens.

@export_group("Coming together")
## Machines have to physically MEET before they can become one thing. This is
## the whole reason a merge is a decision rather than a menu click: the group
## walks to a rendezvous, out of formation, while the fight carries on.
@export var gather_radius_m: float = 3.2
## They hurry to the rendezvous — a merge that took the normal escort speed
## would read as the units wandering off.
@export var gather_speed_mult: float = 1.7
## Give up if they cannot reach each other. Terrain, a trench or a dead member
## must not leave a merge hanging forever.
@export var gather_timeout_s: float = 20.0

@export_group("Group")
## Most machines that can combine into one. Two is the common case; more than
## four turns the convoy inside out in a single order.
@export var max_group: int = 4

@export_group("Cost")
## Reforging is faster than building from raw body — the parts already exist in
## machine form. Multiplies the normal assembly time for the target.
@export_range(0.1, 2.0) var field_work_mult: float = 0.7
@export var min_work_s: float = 2.0
## Mass left over when the pool does not exactly match the target is dropped as
## a wreck on the spot. Conservation holds: nothing is deleted, but the drone
## has to come and fetch it, so overshooting a merge costs a trip.
@export var leftover_as_wreck: bool = true
## Leftovers smaller than this are folded into the new machine instead of
## littering the field with crumbs.
@export var leftover_floor: float = 1.0
