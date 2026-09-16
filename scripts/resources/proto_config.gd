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

@export_group("Camera")
## Where the camera sits relative to the rig it orbits, and how wide it sees.
##
## These were literals in proto_main.gd, which the project rule calls a bug —
## and it was one with teeth: nothing else could read them, so the Blender
## previews had to GUESS the game's camera and guessed a different one.
##
## Steep but not straight down. The reference survey map is drawn flat
## overhead and a camera that copied it would hide every silhouette in the
## game: the arches, the spires and the machines all become circles. This
## offset is about seventy degrees down, which reads as the survey map while
## leaving the props something to be seen by.
@export var camera_offset := Vector3(0.0, 48.0, 17.0)
## VERTICAL field of view in degrees. Godot's Camera3D defaults to
## keep_aspect = KEEP_HEIGHT, which fixes the vertical angle and lets the
## horizontal one open up with the aspect ratio — measured at 2340x1080 this
## is 58 vertical, 100.4 horizontal. Anything reproducing this camera has to
## set the VERTICAL angle or it will frame a different shot.
@export var camera_fov_deg: float = 58.0

@export_group("Models")
@export var module_model: String = "module_forms"
## One entry per growth form, chosen by how much mass the module is carrying.
@export var module_forms: Array[String] = [
	"module_form_0", "module_form_1", "module_form_2"]
@export var drone_model: String = "drone"
@export var swarmer_model: String = "alien_swarmer"
@export var breacher_model: String = "alien_breacher"
## Skinned meshes cannot go through MultiMesh, so every alien is an individual
## animated node. This caps how many get a real body before the rest fall back
## to cheap instanced boxes — the tradeoff Spike A's unit numbers imply.
@export var animated_alien_cap: int = 40
## Above this share of mass, the breacher shows up instead of the swarmer.
@export_range(0.0, 1.0) var breacher_share: float = 0.3

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
##
## Digging costs NO mass, deliberately. Mass is the module's body being
## relocated into units and structures, not a fuel that burns away; moving
## earth is not moving body. The cost of a trench is the time the drone is not
## collecting and the fact that you cannot take it with you.
@export var trench_rate_per_s: float = -1.5
@export var trench_radius_m: float = 1.6
