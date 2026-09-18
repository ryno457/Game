class_name EffectsConfig
extends Resource
## The four effects, and every number in them.
##
## WHY THESE FOUR. Not because they look good in a list — because each one
## fixes something the game currently cannot say:
##
##   hit flash + death   you cannot tell whether a shot connected, and things
##                       vanish mid-stride rather than reading as killed
##   camera shake        artillery has no weight; this costs NOTHING to draw
##   vine wind           the map is full of vines and every one is rigid
##   emerge ring         the 1.5 s climb-out is a deliberate design beat and
##                       it is currently invisible, so the beat does not exist
##
## EVERY ONE HAS ITS OWN SWITCH, and that is the point of this resource. The
## frame budget has never been measured on the phone (CLAUDE.md risk 4), so
## each effect has to be measurable ON ITS OWN rather than as part of a lump
## called "effects". The EFFECTS button in the test build walks these flags and
## restarts the frame timings each time.
##
## The AMOUNTS here are feel questions and the starting values are guesses.
## They are in a .tres so being wrong about them costs an inspector edit.

@export_group("What is on")
@export var hit_flash := true
@export var death_fade := true
@export var camera_shake := true
@export var vine_wind := true
@export var emerge_ring := true

@export_group("Hit flash")
## How long a thing stays lit after being hit. Short: this is a confirmation,
## not a status. Long enough and a swarm under fire reads as permanently white.
@export var flash_s: float = 0.12
## How far toward white. 1.0 is pure white and loses the silhouette.
@export_range(0.0, 1.0) var flash_strength: float = 0.6
## Machines flash too, in their own colour, so a convoy taking damage reads
## without looking at six health bars.
@export var flash_friendly: Color = Color(1.0, 0.42, 0.36)

@export_group("Death")
## How long a corpse takes to go. It is NOT a threat during this: it cannot
## bite, cannot be shot, and is not counted in the hostile tally. A corpse that
## still soaks bullets is worse than no effect at all.
@export var death_s: float = 0.32
## How far it sinks and how far it shrinks over that time.
@export var death_sink_m: float = 0.9
@export_range(0.0, 1.0) var death_shrink: float = 0.55
## A dying thing keels over. Radians at the end of the fall.
@export var death_tip_rad: float = 1.1

@export_group("Camera shake")
## The most the camera will move, in metres, at the strongest hit.
@export var shake_max_m: float = 0.85
## How fast it dies away. Higher is snappier; this is the number most likely to
## be wrong on the first try.
@export var shake_decay: float = 7.0
## How fast it oscillates. Too low reads as a drifting camera rather than a
## thump.
@export var shake_hz: float = 28.0
## Metres of shake per point of damage landed, before distance falls off.
@export var shake_per_damage: float = 0.010
## Beyond this from the view centre, an impact shakes nothing. An explosion
## across the map moving the camera is a bug, not an effect.
@export var shake_range_m: float = 44.0
## Only splash weapons shake by default. Every bolt from twelve machines
## shaking the camera is a vibrating screen, not weight.
@export var shake_splash_only := true

@export_group("Vine wind")
## How far the TOP of a plant moves, in metres. The base never moves.
@export var sway_m: float = 0.22
## Cycles per second. Slow: this is a heavy, humid, sealed biodome.
@export var sway_hz: float = 0.32
## The height at which a plant sways the full amount. Taller parts sway more,
## in proportion, so one number works for a 1 m pod and a 9 m vine.
@export var sway_ref_h: float = 3.0

@export_group("Emerge ring")
## The ring starts here and ends here, in metres, over the emerge time.
@export var ring_from_m: float = 0.4
@export var ring_to_m: float = 2.6
## How many discs make the ring. More is smoother and costs marker slots.
@export_range(3, 24) var ring_dots: int = 10
@export var ring_colour: Color = Color(0.86, 0.72, 0.48, 0.55)
