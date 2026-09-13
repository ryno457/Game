class_name TerrainConfig
extends Resource
## Heightfield thresholds and deformation rates.
##
## Heights are normalized 0-1. Any change here must be re-verified against
## `impassable_below` by a headless test — deformation that looks like it works
## but never breaches the threshold is the single most expensive mistake this
## project has already made once.

@export_group("Grid")
@export var cells_x: int = 150
@export var cells_z: int = 112
@export var cell_size_m: float = 1.0
@export var height_scale_m: float = 12.0
@export var worldgen_seed: int = 20260913

@export_group("Passability")
@export var neutral_height: float = 0.50
@export var impassable_below: float = 0.26
@export var rough_below: float = 0.38
@export var rough_speed_multiplier: float = 0.55
@export var clamp_min: float = 0.02
@export var clamp_max: float = 0.98

@export_group("Deformation rates")
## Deliberate, fast, and deep enough to actually breach `impassable_below`.
@export var excavator_rate_per_s: float = -1.5
@export var excavator_radius_m: float = 1.6
## Attached excavator smooths toward neutral. Rate-based, NOT per-frame — the
## prototype's per-frame lerp made dig depth depend on framerate.
@export var flatten_rate_per_s: float = 6.0
@export var flatten_radius_m: float = 2.1

@export_group("Incidental scarring")
## Small and cumulative. Long firefights near a static turret will otherwise
## dig a moat that traps the player's own units.
@export var weapon_scar_delta: float = -0.011
@export var weapon_scar_radius_m: float = 1.0
## Incidental scarring floors here rather than at `clamp_min`, so weapons can
## roughen ground but can never sever it.
@export var scar_floor: float = 0.38
@export var mining_scar_delta: float = -0.016
@export var mining_scar_radius_m: float = 1.25
@export var deploy_impact_delta: float = -0.03
@export var deploy_impact_radius_m: float = 1.9
