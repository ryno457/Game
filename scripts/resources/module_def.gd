class_name ModuleDef
extends Resource
## One of the six chassis modules. Every module must do something genuinely
## useful attached AND detached, or the core decision of the game collapses.

@export var id: StringName = &""
@export var display_name: String = ""
@export var glyph: String = ""
@export var salvage_cost: int = 0

@export_multiline var attached_description: String = ""
@export_multiline var detached_description: String = ""

@export_group("Attached effect")
## Behaviour script instanced as a child of the chassis while attached.
## Detaching reparents the node; it never changes type.
@export var attached_behaviour: Script
@export var bonus_hull: float = 0.0
@export var damage: float = 0.0
@export var range_m: float = 0.0
@export var cooldown_s: float = 0.0
@export var mine_yield: float = 0.0
@export var mine_interval_s: float = 0.0
## Multiplicative, per copy attached. 1.0 means no effect.
@export var speed_multiplier: float = 1.0

@export_group("Detached form")
@export var unit_stats: UnitStats
@export var detached_scene: PackedScene

@export_group("Recall")
## Recall must cost something — free instant recall removes the decision.
## See CLAUDE.md. These are the levers; pick one, not all three.
@export var recall_cooldown_s: float = 0.0
@export var recall_salvage_cost: int = 0
## Seconds the module spends travelling home, vulnerable, before it re-seats.
@export var recall_travel_s: float = 0.0
