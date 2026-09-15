class_name CloudConfig
extends Resource
## The cloud deck the map's peaks stand above.
##
## The map is a high mountain range, not a floating island: below the lowest
## ground there is weather, not space. Height here is in WORLD metres, so it
## has to sit below the terrain's own lowest drawn point — `void_below` on the
## palette decides where the ground stops, this decides what is under it.

@export var display_name: String = ""

@export_group("Placement")
## World Y of the deck. Below the terrain's lowest drawn ground, far enough
## that the peaks read as standing over a drop rather than paddling in it.
@export var height_m: float = -22.0
## Half-extent of the plane. Generous: it has to reach past the map on every
## side or the player can pan to its edge and see the world end.
@export var extent_m: float = 520.0

@export_group("Look")
@export var lit_colour: Color = Color(0.86, 0.93, 1.0)
@export var shadow_colour: Color = Color(0.19, 0.28, 0.40)
## What shows through the gaps in the cloud: the drop itself.
@export var deep_colour: Color = Color(0.05, 0.09, 0.16)
## The deck blends to this at the rim so the plane has no visible edge.
@export var horizon_colour: Color = Color(0.30, 0.55, 0.62)

@export_group("Weather")
@export var cloud_scale: float = 0.012
## How much of the deck is cloud rather than gap. Higher is more solid.
@export_range(0.0, 1.0) var coverage: float = 0.48
@export_range(0.01, 1.0) var softness: float = 0.30
## Metres per second of drift. Slow: this is seen from a long way up.
@export var scroll_mps: float = 0.6
@export_range(0.0, 2.0) var relief: float = 0.55

@export_group("Distance")
@export var fade_start_m: float = 180.0
@export var fade_end_m: float = 420.0
