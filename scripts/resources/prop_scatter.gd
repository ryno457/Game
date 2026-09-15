class_name PropScatter
extends Resource
## One kind of scenery and the rules for where it grows.
##
## A scatter rule, not a placement list. A biodome map is a seed plus a
## deformation diff (CLAUDE.md risk item 3), so its dressing has to be
## reproducible from a seed too — a saved list of two hundred transforms is
## exactly the megabytes-per-save mistake that rule exists to prevent.

@export var model: String = ""
@export var count: int = 40

@export_group("Where")
## Normalized height band this will grow in. Pools are below `impassable_below`
## (0.26) and ridges are above 0.60, so a band is how a prop is told to be a
## shoreline thing, a lowland thing or a clifftop thing.
@export var height_min: float = 0.26
@export var height_max: float = 1.0
## Steepest ground it will stand on, as 1 - normal.y. Nothing grows on a wall.
@export_range(0.0, 1.0) var max_slope: float = 0.45
## Keep this far from anything else already placed, and from the landing site.
@export var clearance_m: float = 2.0

@export_group("Clumping")
## Growth is not evenly spread in a cavern — it crowds where the light and the
## water are and leaves bare ground between. Zero scatters uniformly across the
## whole legal band; anything else picks this many thickets first and grows
## everything inside one of them.
@export var clusters: int = 0
@export var cluster_radius_m: float = 9.0

@export_group("How")
@export var scale_min: float = 0.8
@export var scale_max: float = 1.35
## Sink into the ground. A tendril that sits exactly on the surface reads as a
## sticker; a few centimetres under and it reads as growing out of it.
@export var sink_m: float = 0.08
## Tilt to follow the slope. Rock does; a plant that grew upward does not.
@export_range(0.0, 1.0) var follow_slope: float = 0.35
## Shadow casting is the expensive half of scenery on a phone — every instance
## is drawn again into the shadow atlas. Worth it for something big enough that
## a missing shadow reads as floating; not worth it for ankle-high clutter.
@export var casts_shadow: bool = true
