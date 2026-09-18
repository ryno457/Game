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

## THE DRONE DOES NOT COLLECT ON ITS OWN. It used to fly to the nearest piece
## whenever it was idle, which meant the mass economy ran itself and the player
## watched. Tapping a piece is now the order. Off here rather than deleted so
## the old behaviour can be measured against the new one.
@export var drone_auto_collect: bool = false
## How close a tap has to land to count as tapping a piece. Generous: this is a
## thumb on a phone, aimed at something a few pixels across.
@export var drone_order_reach_m: float = 5.0

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
## How far the module may drift from the centre of the view before the camera
## starts moving to keep up, and how fast it closes that gap.
##
## The camera used to be welded to the module, which made the pan gesture
## useless — it was undone on the next simulation step. Zero here restores the
## weld; a value larger than the screen means the camera never follows at all.
## SCALED BY THE ZOOM. A 16 m leash is most of the screen zoomed out and more
## than the whole of it zoomed in, so a fixed leash would lose the module the
## moment the player came in close.
@export var camera_leash_m: float = 16.0
@export var camera_follow: float = 2.5

@export_group("Zoom")
## Three rungs, WIDEST FIRST, as multipliers on camera_offset. A multiplier
## rather than three offsets because the camera must keep its pitch: a zoom
## that also changes the angle reads as cutting to a different camera, not as
## moving closer. Rung 0 is the framing the game shipped with.
@export var camera_zoom_steps: PackedFloat32Array = PackedFloat32Array(
	[1.0, 0.62, 0.38])
## How fast the camera eases between rungs. Snapping is disorienting on a map
## the player is navigating by landmark.
@export var camera_zoom_lerp: float = 9.0
## Two fingers closer together than this are one fat thumb, not a pinch.
@export var pinch_deadzone_px: float = 24.0
## A pinch drives the zoom continuously and settles on the nearest rung when
## the fingers lift, so the gesture feels live but the game still has three
## named levels. This is how much of the span one screen-width of pinch covers.
@export var pinch_gain: float = 1.0

@export_group("Projectiles")
## Shots TRAVEL. Damage used to land the instant a cooldown came up, which
## meant a firefight was two groups of models standing still and one of them
## quietly losing. Per weapon family, because a bolt and a mortar shell are
## not the same object.
##
## MELEE HAS NO SPEED AND NO PROJECTILE. A claw with a flight time would swing
## at something that has already walked away.
@export var shot_speed_ranged_mps: float = 34.0
@export var shot_speed_artillery_mps: float = 19.0
## How high a shell arcs, as a fraction of the gap it crosses. Presentation
## only — the sim tracks a flat position, and the arc is added when drawing.
@export var shot_arc: float = 0.22
@export var shot_size_m: float = 0.34
## A shot whose target dies mid-flight keeps going to where it was aimed. A
## shell still lands; a direct-fire bolt simply misses, which is the cost of
## the travel time being real.
@export var shot_cap: int = 192

@export_group("Health bars")
@export var bar_width_m: float = 2.4
@export var bar_height_m: float = 0.4
## How far above the thing it floats, before that thing's own size is added.
@export var bar_lift_m: float = 1.2
## A bar over every one of seventy swarmers is noise, not information. Things
## the player makes decisions about — machines, the module, the roamers and the
## plant nests — always carry one; a small alien earns one by being hurt.
@export var bar_always_for: Array[StringName] = [&"roamer", &"nest"]

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
## How much bigger a roaming creature is than a swarmer, and how much slower.
## Two of them walk the map in the open; see HiveConfig.
@export var roamer_scale: float = 2.6
## A nest is a plant, so it does not move and it does not bite. It is a thing
## with hit points standing where the dressing already put a plant.
@export var nest_scale: float = 1.7

@export_group("The module")
## THE MODULE WALKS. It used to teleport: a tap set module_pos and the camera
## jumped, which is why it read as respawning rather than moving. Tapping now
## sets a goal and it drives there, which also means it can be caught out of
## position — the whole point of a body that carries your mass.
## 3.6, down from 6.5. At 6.5 the module crossed the 150 m map in 23 seconds,
## which is fast enough that being caught out of position never happened — and
## being catchable is the entire reason it walks instead of teleporting. At 3.6
## the crossing is 42 seconds and deciding where to stand is a real commitment.
@export var module_speed_mps: float = 3.6
## How close counts as arrived.
@export var module_arrive_m: float = 0.6

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
