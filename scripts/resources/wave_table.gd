class_name WaveTable
extends Resource
## Hostile wave composition and scaling for one biodome.

@export var interval_s: float = 45.0
@export var fragments_required: int = 5
@export var teleporter_charge_s: float = 35.0

@export_group("Hostile scaling")
@export var count_base: float = 2.0
@export var count_per_wave: float = 1.4
@export var hp_base: float = 60.0
@export var hp_per_wave: float = 10.0
@export var speed_base_mps: float = 42.0
@export var damage_base: float = 9.0
@export var damage_per_wave: float = 1.6
@export var attack_cooldown_s: float = 1.0
@export var radius_m: float = 1.0
@export var target_acquire_m: float = 26.0
@export var spawn_scatter_m: float = 3.5

@export_group("Rewards")
@export var salvage_per_kill: int = 6
@export var salvage_per_nest: int = 45


func hostile_count(wave_index: int) -> int:
	return int(count_base + floor(wave_index * count_per_wave))
