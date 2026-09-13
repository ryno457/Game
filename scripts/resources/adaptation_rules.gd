class_name AdaptationRules
extends Resource
## How the hive reads the player and what it grows in response.
##
## Reliance is sampled in UNIT-SECONDS — one shared currency for all three
## tactics. The prototype originally compared deploy *counts* against dig
## *seconds*, which is not a comparison at all.

## Tactic key -> adaptation id. Keys must match what RelianceSampler reports.
@export var counters: Dictionary = {
	&"turret": &"chitin_plating",
	&"drone": &"sprint_glands",
	&"trench": &"burrowing",
}

@export_group("Gating")
## Total reliance below this means the hive learned nothing this wave.
## Without it, an idle player is read as whichever tactic sorts first.
@export var min_reliance_s: float = 6.0
## The leading tactic must hold at least this share of the total, or the wave
## is treated as mixed play and grants nothing. This is what makes switching
## tactics an actual defence rather than a slower loss.
@export var min_share: float = 0.40

@export_group("Effects per stack")
@export var chitin_bonus_hp: float = 30.0
## Damage taken multiplier is max(resist_floor, 1 - stacks * resist_per_stack).
@export var chitin_resist_per_stack: float = 0.14
@export var chitin_resist_floor: float = 0.45
@export var sprint_bonus_mps: float = 13.0
## Burrowing aliens ignore heightfield passability. They are still dome-bound.
@export var burrow_ignores_terrain: bool = true

@export_group("Presentation")
## Adaptations must be legible in the HUD or they read as unfair scaling.
@export var display_names: Dictionary = {
	&"chitin_plating": "Chitin Plating",
	&"sprint_glands": "Sprint Glands",
	&"burrowing": "Burrowing",
}
