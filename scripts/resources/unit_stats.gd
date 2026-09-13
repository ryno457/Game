class_name UnitStats
extends Resource
## Stats for a module in its DETACHED state — the unit or structure it becomes.
## Values carried from docs/prototype-balance.md.

@export var id: StringName = &""
@export var display_name: String = ""

@export_group("Survivability")
@export var max_hp: float = 100.0
@export var radius_m: float = 1.0

@export_group("Movement")
## 0 means static — a turret or beacon. Static units count as turret defence
## for adaptation purposes; anything that moves counts as drone play.
@export var speed_mps: float = 0.0

@export_group("Combat")
@export var damage: float = 0.0
@export var range_m: float = 0.0
@export var cooldown_s: float = 0.9
## How far a mobile armed unit will chase before it stops acquiring.
@export var acquire_range_m: float = 0.0
## Mobile units close to this fraction of `range_m` before firing.
@export var standoff_ratio: float = 0.8

@export_group("Utility")
@export var repair_per_s: float = 0.0
@export var mine_yield: float = 0.0
@export var mine_interval_s: float = 0.0
@export var cargo_capacity: float = 0.0
## Heightfield delta per second while this unit is actively digging.
@export var dig_rate_per_s: float = 0.0
@export var dig_radius_m: float = 0.0


func is_static() -> bool:
	return is_zero_approx(speed_mps)
