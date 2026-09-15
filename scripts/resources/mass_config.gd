class_name MassConfig
extends Resource
## The mass economy. Mass is the module's body, not a currency beside it.

@export var starting_mass: float = 30.0
## Below this the module cannot build. It is a floor, not a loss state — see
## the open question in docs/loop-v2.md.
@export var reserve_mass: float = 8.0
@export var max_mass: float = 400.0

@export_group("Module presentation")
## Module scale is mapped from mass so spending is visible without a UI.
@export var scale_at_min: float = 0.55
@export var scale_at_max: float = 2.2
## Seconds for the module to visibly settle after mass changes.
@export var scale_tween_s: float = 0.45

@export_group("Recovery")
## MASS IS CONSERVED. Both losses are zero and should stay zero: mass is the
## module's body relocated into units and structures, never consumed. A
## percentage tax would quietly delete body, which the rule forbids.
##
## What stops free repurposing is TIME, not attrition:
##   - a wreck sits where it fell until the drone flies out and hauls it back
##   - scrapping a live unit turns it into a wreck, so it takes the same trip
##   - building takes `build_time_for(mass)`, during which it is committed and
##     the unit does not exist yet
## Churn therefore costs minutes of drone work and a hole in your line, which
## is a real price without breaking conservation.
@export_range(0.0, 1.0) var recovery_loss: float = 0.0
@export_range(0.0, 1.0) var scrap_loss: float = 0.0
## Seconds to assemble a machine once its mass is committed.
##
## This is the ENTIRE cost of repurposing, so it is the most load-bearing
## number in the economy. Too short and churn is free; too long and trying a
## different loadout is punished. It is deliberately in the middle: the
## cheapest thing in the catalogue lands under five seconds, the heaviest just
## over ten.
##
## Scaled by mass rather than flat, because a Siege Battery arriving as fast as
## a Bulwark makes the size of a machine mean nothing. A flat time also makes
## merging two units into a bigger one free, which is exactly the decision the
## merge rules exist to charge for.
##
##     seconds = build_time_base_s + mass * build_time_per_mass_s
##
##     Bulwark        10 mass ->  4.5 s
##     Skirmisher     14 mass ->  5.2 s
##     Lancer         26 mass ->  7.3 s
##     Siege Battery  42 mass -> 10.1 s
@export var build_time_base_s: float = 2.7
@export var build_time_per_mass_s: float = 0.175
## Floor and ceiling, so a tuning pass on the two numbers above can never
## produce an instant build or one that outlasts a wave.
@export var build_time_min_s: float = 2.0
@export var build_time_max_s: float = 16.0


## Seconds to assemble a machine of this mass.
func build_time_for(machine_mass: float) -> float:
	return clampf(build_time_base_s + machine_mass * build_time_per_mass_s,
		build_time_min_s, build_time_max_s)
