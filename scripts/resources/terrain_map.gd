class_name TerrainMap
extends Resource
## A designed test terrain, stored as a SEED plus a list of operations.
##
## Deliberately not a stored heightfield. CLAUDE.md risk item 3 says a save
## must be "the procedural seed plus a deformation diff" rather than megabytes
## of floats — so the test maps are authored in exactly that format. If this
## representation cannot express the maps we want, we learn it now rather than
## at save/load time.
##
## Ops are applied in order. Each is a Dictionary with an "op" key:
##   crater  {x, z, r, amount}              cosine-falloff dent
##   trench  {x0, z0, x1, z1, r, amount}    swept line of dents
##   plateau {x, z, r, level, strength}     pull a disc toward a height
##   band    {x0, z0, x1, z1, level, edge}  pull a rect toward a height
##   polygon {points, level, edge, strength} fill a traced outline
##   wall    {points}                        INVISIBLE WALL: marks cells
##                                           impassable and changes no heights

@export var display_name: String = ""
@export var terrain: TerrainConfig

@export_group("Base")
@export var noise_seed: int = 20260913
## Height the base noise sits around. Negative means "use the TerrainConfig's
## neutral_height", which is what a continuous map wants.
##
## An ARCHIPELAGO map sets this far below the palette's `void_below`, so the
## default state of the world is "no ground here" and every island is something
## the ops list explicitly raised.
@export var base_level: float = -1.0
@export var amplitude: float = 0.30
## Each entry is (frequency, weight). Weights should sum to about 1.
@export var octaves: Array[Vector2] = [
	Vector2(0.055, 0.60), Vector2(0.14, 0.28), Vector2(0.31, 0.12),
]

@export_group("Features")
@export var ops: Array[Dictionary] = []

@export_group("Mission anchors")
@export var spawn: Vector2 = Vector2.ZERO
@export var goal: Vector2 = Vector2.ZERO
