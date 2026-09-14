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
## Fraction of a unit's mass lost when its wreck is recovered. Without a loss,
## building and scrapping is free and the decision collapses — the same trap
## CLAUDE.md records for free module recall. Feel question; tune here.
@export_range(0.0, 1.0) var recovery_loss: float = 0.25
## Fraction lost when a live unit is voluntarily scrapped back into the module.
@export_range(0.0, 1.0) var scrap_loss: float = 0.15
