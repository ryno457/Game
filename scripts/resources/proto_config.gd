class_name ProtoConfig
extends Resource
## Tunables for the first-minutes prototype.
##
## These started as consts in the scene script, which CLAUDE.md calls a bug:
## "If a number is in a .gd file, that is a bug." They are here so the loop can
## be tuned without touching code.

@export_group("Drone")
@export var drone_speed_mps: float = 11.0
@export var drone_reveal_m: float = 9.0
## Seconds to lift a loose piece. Stuck pieces use `large_free_s`.
@export var small_free_s: float = 1.2
@export var large_free_s: float = 26.0

@export_group("Debris")
@export var small_mass: float = 9.0
@export var large_mass: float = 55.0
@export var small_count: int = 9
@export var large_count: int = 3
@export var small_spread_m: Vector2 = Vector2(8.0, 34.0)
@export var large_spread_m: Vector2 = Vector2(44.0, 70.0)

@export_group("Module")
@export var module_reveal_m: float = 22.0
## Mass lost per second per hostile in contact with the module. The module IS
## its mass, so being chewed on costs body — but slowly enough that the player
## can respond. Set too high this reads as an instant loss with no counterplay.
@export var module_drain_per_s: float = 0.4

@export_group("Hostiles")
@export var alien_speed_mps: float = 4.6
@export var alien_damage: float = 7.0
@export var alien_attack_cd_s: float = 1.0
@export var alien_radius_m: float = 0.55
@export var spawn_ring_m: Vector2 = Vector2(46.0, 60.0)

@export_group("Convoy")
## Fallback station-keeping when a BuildOption does not override it.
@export var escort_radius_m: float = 6.0
@export var escort_lerp: float = 0.8
## Station-keeping is a spring, not a leash: a unit that falls behind closes
## faster. Without this the convoy strings out and stops reading as one force.
@export var escort_catchup: float = 2.4

@export_group("Trenching")
## Trenches are the one thing that stays where it was built. Rate is per second
## and must comfortably breach impassable_below, or a trench is a cosmetic dent
## — the mistake CLAUDE.md records from the first prototype.
@export var trench_rate_per_s: float = -1.5
@export var trench_radius_m: float = 1.6
## Mass spent per second of digging. Digging is not free; it is the cheapest
## permanent defence in the game and should still cost body.
@export var trench_mass_per_s: float = 0.6
