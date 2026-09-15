class_name BiomePalette
extends Resource
## The look of a biodome's ground, as data.
##
## The terrain shader used to carry its palette as uniform defaults, which put
## a dozen tunable numbers in a file CLAUDE.md says must not hold any. These
## are the same numbers, editable without recompiling a shader — and the reason
## two biodomes can look nothing alike without a second shader existing.

@export var display_name: String = ""

@export_group("Bands")
## Below `impassable_below` the ground is not a hole, it is standing liquid.
@export var col_pool: Color = Color(0.03, 0.30, 0.29)
@export var col_rough: Color = Color(0.16, 0.26, 0.20)
@export var col_ground: Color = Color(0.20, 0.26, 0.27)
@export var col_ridge: Color = Color(0.62, 0.64, 0.60)
@export var col_cliff: Color = Color(0.12, 0.14, 0.17)
@export var fog_tint: Color = Color(0.02, 0.04, 0.06)

@export_group("Bioluminescence")
## The pools are the brightest thing on the map and the main fill light in a
## cavern with one weak sun. Emission, not albedo — they have to read through
## the fog tint and light the things standing in them.
@export var pool_glow: Color = Color(0.18, 0.94, 0.82)
@export_range(0.0, 8.0) var pool_glow_strength: float = 2.4
## Filaments in the rock. Derived from the noise the shader already samples, so
## they cost arithmetic rather than another texture fetch.
@export var vein_glow: Color = Color(0.25, 0.92, 0.70)
@export_range(0.0, 4.0) var vein_strength: float = 0.55
@export var vein_scale: float = 0.055
## How tight the filaments are. Higher is a finer web.
@export_range(1.0, 24.0) var vein_sharpness: float = 9.0

@export_group("Readability")
## The red line exactly at the impassable threshold. Grey-box readability aid,
## not art: set to 0 for screenshots, back to 0.85 to check a trench actually
## severed the ground.
@export_range(0.0, 1.0) var threshold_line_strength: float = 0.85
