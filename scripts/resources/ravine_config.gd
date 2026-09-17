class_name RavineConfig
extends Resource
## The mountain ravine the map sits inside.
##
## This replaces CloudConfig. The map used to be peaks standing over a weather
## deck: below the lowest drawn ground there was cloud, and where the terrain
## discarded itself you saw sky. The brief changed — a mountain ravine, moonlit,
## with the playable ground on its floor — and a scrolling cloud plane cannot
## be tuned into that. It is a different object.
##
## WHY THIS IS NOT PART OF THE HEIGHTFIELD. The traced outline reaches to within
## three metres of the map frame on the west side, so there is no room outside
## it for a wall; and the terrain grid is the thing the flow field, the material
## classifier and the whole-map detail bake all run over, so widening it to make
## room costs 1.7x on every one of them. The ravine is scenery — nothing walks
## on it, nothing is placed on it, nothing paths through it — so it is built as
## its own coarse mesh and the heightfield is left exactly as it is.
##
## All heights here are WORLD METRES, measured from y = 0, which is the
## terrain's own zero. The map's highest ground is height_scale_m, so a crest
## has to clear that or the walls stand below the ground they enclose.

@export var display_name: String = ""

@export_group("The cleft")
## World Y of the ravine floor — the dark bottom seen through every gap in the
## terrain, and through the two notches in the outline.
@export var floor_y_m: float = -17.0
## How far out from the map frame the floor stays flat before the wall starts.
## This is the width of the visible chasm, and it is the number that decides
## whether the walls read as a ravine or as a fence around a table.
@export var floor_width_m: float = 13.0
## Roughness of the floor itself, in metres of relief.
@export var floor_relief_m: float = 2.2

@export_group("The walls")
## How high the crest stands above y = 0.
@export var crest_y_m: float = 46.0
## Horizontal run the wall takes to reach the crest from the end of the floor.
## Crest rise over this run is the wall's slope: keep it under 1.0 and the
## ravine reads as a valley instead.
@export var rise_run_m: float = 52.0
## Shapes the rise. Above 1 the wall leaves the floor steeply and eases into
## the crest, which is what a scree-footed rock wall does.
@export_range(0.3, 4.0) var rise_curve: float = 1.85
## Ridge noise on the crest, in metres, so the skyline is not a smooth lip.
@export var ridge_relief_m: float = 11.0
@export var ridge_scale: float = 0.018
## Second, finer band of relief — the gullies down the wall face.
@export var gully_relief_m: float = 4.5
@export var gully_scale: float = 0.075
## How far the foot of the wall wanders in and out, in metres. Zero puts a
## constant-width chasm and a square corner around the map — see
## RavineWall._ring_vertex, which is where this is the whole difference between
## a ravine and a picture frame.
@export var edge_wander_m: float = 7.0
## Distance over which the ring blends from the map's rectangle to a circle.
@export var round_over_m: float = 46.0

@export_group("Extent")
## Half-extent of the whole surround. Must reach past anywhere the camera can
## pan to, or the player sees the world end.
@export var extent_m: float = 420.0
## Mesh resolution along the wall, in metres. The ring is the only geometry
## here; at 3 m over a 524 m perimeter it is about 8k triangles.
@export var wall_cell_m: float = 3.4
## Mesh resolution of the floor under the map. Coarse: it is mostly hidden
## behind the terrain and only shows through the gaps.
@export var floor_cell_m: float = 7.0

@export_group("Colour")
## The cleft bottom. Nearly black, and NOT light grey — that value belongs to
## the machines and a landscape that shares it hides them.
@export var deep_colour: Color = Color(0.031, 0.055, 0.060)
## The wall face.
@export var rock_colour: Color = Color(0.086, 0.130, 0.132)
## The crest, where the moon actually reaches.
@export var crest_colour: Color = Color(0.170, 0.213, 0.224)
## Mixed into the crest on the sun-facing flanks only, so the range has a lit
## side and a dark side rather than one even tone all the way round.
@export var moonlit_colour: Color = Color(0.268, 0.316, 0.372)
## How bright the whole range sits against the ground, as one number. The four
## colours above are a GRADIENT and this is its level — see RavineWall._material
## for why the two are separate. Measured: at 0.42 the chasm floor renders at
## 5/255 and the crest at 14/255, which is not a dark ravine, it is a hole.
@export var wall_albedo: Color = Color(1.0, 1.0, 1.0)
@export var seed: int = 20260917
