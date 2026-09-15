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

@export_group("The edge of the world")
## Ground below this is NOT DRAWN — the map becomes peaks of a high range
## standing above a cloud deck rather than a continuous valley. Zero keeps the
## ground continuous, which is what a normal map wants.
##
## Distinct from `impassable_below`, which is where units may not walk. This
## sits lower, so between the two there is a rim of real-but-impassable ground:
## the cliff edge a peak falls away over.
@export_range(0.0, 0.5) var void_below: float = 0.0

@export_group("Survey grid")
## Metres between grid lines. Zero is off. A readability aid for judging
## distance from a top-down camera, not decoration — and drawn with screen-space
## derivatives so a line stays one pixel wide at any zoom.
@export var grid_spacing_m: float = 0.0
@export var grid_colour: Color = Color(0.55, 0.85, 0.92)
@export_range(0.0, 1.0) var grid_strength: float = 0.18
@export var grid_width_px: float = 1.4

@export_group("Bioluminescence")
## The pools are the brightest thing on the map and the main fill light in a
## cavern with one weak sun. Emission, not albedo — they have to read through
## the fog tint and light the things standing in them.
@export var pool_glow: Color = Color(0.18, 0.94, 0.82)
@export_range(0.0, 8.0) var pool_glow_strength: float = 2.4
## Filaments in the rock. Derived from the noise the shader already samples, so
## they cost arithmetic rather than another texture fetch.
## A second pool colour. Which one a pool gets is decided by a very
## low-frequency noise, so a map has teal water in one basin and violet in the
## next rather than one uniform tint everywhere.
@export var pool_glow_alt: Color = Color(0.72, 0.28, 0.95)
@export_range(0.0, 1.0) var pool_alt_mix: float = 0.0
@export var vein_glow: Color = Color(0.25, 0.92, 0.70)
@export_range(0.0, 4.0) var vein_strength: float = 0.55
@export var vein_scale: float = 0.055
## How tight the filaments are. Higher is a finer web.
@export_range(1.0, 24.0) var vein_sharpness: float = 9.0

@export_group("Surface detail")
## There are no textures in this project — no image files, no UVs on any mesh —
## so ground quality is procedural surface, not bitmap resolution. These are
## the knobs for how much of it to pay for, and the quality preset overrides
## `detail_strength` at runtime.
##
## Bump depth from a one-octave noise gradient. Zero skips the two extra taps
## entirely, which is most of what a low preset saves.
@export_range(0.0, 3.0) var detail_strength: float = 0.9
## Cycles per metre. Around 2-3 reads as grit at the RTS camera height; much
## finer than that is invisible and shimmers when the camera pans.
@export var detail_scale: float = 2.6
## Past this distance the bump fades out and stops being computed at all.
@export var detail_fade_m: float = 55.0
## One very low-frequency colour drift across the whole valley, so a hundred
## square metres of ground is not a single flat material with grain on it.
@export_range(0.0, 1.0) var macro_strength: float = 0.16
@export var macro_scale: float = 0.018
## Horizontal bedding on steep faces. The cheapest thing that makes a cliff
## read as rock rather than as a grey ramp.
@export_range(0.0, 1.0) var striation_strength: float = 0.30

@export_group("Readability")
## The red line exactly at the impassable threshold. Grey-box readability aid,
## not art: set to 0 for screenshots, back to 0.85 to check a trench actually
## severed the ground.
@export_range(0.0, 1.0) var threshold_line_strength: float = 0.85
