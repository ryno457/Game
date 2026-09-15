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
##   - building takes `build_time_s`, during which the mass is committed and
##     the unit does not exist yet
## Churn therefore costs minutes of drone work and a hole in your line, which
## is a real price without breaking conservation.
@export_range(0.0, 1.0) var recovery_loss: float = 0.0
@export_range(0.0, 1.0) var scrap_loss: float = 0.0
## Seconds to assemble a unit once its mass is committed.
@export var build_time_s: float = 4.0
