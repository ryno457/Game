class_name BiomePalette
extends Resource
## The look of a biodome's ground, as data.
##
## The terrain shader used to carry its palette as uniform defaults, which put
## a dozen tunable numbers in a file CLAUDE.md says must not hold any. These
## are the same numbers, editable without recompiling a shader — and the reason
## two biodomes can look nothing alike without a second shader existing.

@export var display_name: String = ""

@export_group("Ground materials")
## Five slots, in GroundMaterials index order. The reference map is large flat
## areas of different stuff with hard borders, not one surface shaded by
## altitude — and only the root-mat slot grows the glowing web, which is what
## keeps the vines to the plateau rims instead of carpeting everything.
@export var materials: Array[GroundMaterial] = []
## How far the material lookup is jittered by noise. This is what turns the
## cell grid into a torn organic border rather than a staircase.
@export var material_jitter_m: float = 1.8
## Cycles per metre of the jitter noise. Must be FASTER than one cell or the
## borders keep their staircase: the whole point is that two fragments inside
## the same cell land in different slots.
@export var material_jitter_scale: float = 1.1

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
## Ground under this height is CHANNEL — the plate between the raised lobes.
## The root mat grows there as well as around the outer rim, because in the
## reference the web fills every gap between plateaus rather than merely
## outlining the mass. Zero disables it.
@export_range(0.0, 1.0) var channel_below: float = 0.0
## How thin the channel strands are. Higher is thinner — this is the knob that
## decides how much of the map is root mat versus open ground.
@export_range(0.5, 0.98) var channel_web_threshold: float = 0.82
## How WIDE a root strand is, in metres. Separate from the threshold above, and
## the reason the strands stopped reading as scribble: the threshold picks WHICH
## contour the strands follow, this picks how thick the ribbon around it is.
## Thresholding alone gave a band whose width varied with the local noise
## gradient, which is a filigree rather than a root.
@export var channel_strand_width_m: float = 5.0

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
## How much the bioluminescence appears to LIGHT the ground around it.
## Free: the distance fields these ramp off are already fetched for the tube
## and the shoreline, so this costs no extra texture tap.
@export_range(0.0, 2.0) var bio_pool_gain: float = 0.0
@export var bio_pool_reach_m: float = 6.0
@export_range(0.0, 2.0) var bio_root_gain: float = 0.0
@export var bio_root_reach_m: float = 2.5

@export_group("Surface detail")
## There are no textures in this project — no image files, no UVs on any mesh —
## so ground quality is procedural surface, not bitmap resolution. These are
## the knobs for how much of it to pay for, and the quality preset overrides
## `detail_strength` at runtime.
##
## Bump depth from a one-octave noise gradient. Zero skips the two extra taps
## entirely, which is most of what a low preset saves.
@export_range(0.0, 3.0) var detail_strength: float = 0.9
## The same detail field as a COLOUR shift rather than a normal tilt. This is
## the one that reaches the screen at a top-down camera; the bump barely does.
@export_range(0.0, 1.0) var detail_albedo: float = 0.0
## Detail BAKED from art/detail_source.blend rather than generated by noise,
## covering the WHOLE map in one texture. There is no tile size because there
## is no tile: the terrain is a fixed shape now, so it carries a real unwrap.
@export_range(0.0, 2.0) var baked_normal: float = 0.0
@export_range(0.0, 1.0) var baked_colour: float = 0.0
## A dark line along every baked form. The depth-based ink pass cannot draw
## these: the vines are a normal map on flat ground and change no depth at all.
@export_range(0.0, 1.0) var baked_ink: float = 0.0
@export var baked_ink_power: float = 2.2
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

@export_group("Distance gradients")
## Ramps off the baked distance fields. THIS is what replaces posterised bands
## with gradients: almost every gradient in the reference is a distance, not a
## height, and two places at the same height shade differently depending how far
## they are from a feature.
##
## Metres the fields are normalised over. Must match what bake_fields used.
@export var field_range_m: float = 20.0
## Ground darkens as it nears the drop — the soft contact shadow a painted map
## puts around every raised shape.
@export_range(0.0, 1.0) var edge_shade: float = 0.38
@export var edge_falloff_m: float = 9.0
## And beside every root strand, which is what makes a strand read as a raised
## tube rather than a green line drawn on the floor.
@export_range(0.0, 1.0) var strand_shade: float = 0.30
@export var strand_falloff_m: float = 3.0
## The SIGNED range the strand channel is encoded over, in metres. Short on
## purpose and separate from field_range_m: at the shared 20 m a 1.8 m tube
## spans about 23 of the 256 codes, so the one feature the channel exists to
## make smooth was being banded by its own encoding.
@export var strand_range_m: float = 4.0
## Bleaching toward a waterline.
@export_range(0.0, 1.0) var shore_pale: float = 0.45
@export var shore_falloff_m: float = 7.0
## Root strands shaded as rounded TUBES, straight out of the distance field: at
## distance d from a strand a circular cross-section of radius r rises by
## sqrt(r^2-d^2) and its normal tilts away by d/r. Lit crest, shadowed base, no
## geometry and no normal map. Zero disables it.
@export var tube_radius_m: float = 1.6
@export_range(0.0, 1.0) var tube_blend: float = 0.80

@export_group("Painted light")
## The shading model, replacing posterised Lambert.
##
## A painted top-down map gets its form from three separate dark things and one
## colour rule, and the banded version had none of them:
##
##  1. AO — omnidirectional contact darkening where ground meets anything
##     raised. Without it a plateau floats above the plate it sits on.
##  2. A DIRECTIONAL cast shadow, which is the cue that says where the light is.
##  3. CURVATURE — a bright line along every convex crest and a dark one in
##     every concave crease. This is what makes a root read as a tube and a
##     trench read as dug.
##  4. Shadows are a HUE PATH, not a value ramp. Into shadow, colour goes
##     darker, cooler, and MORE SATURATED in the crease. That is a gradient
##     map, and it is why this is a ramp texture rather than a multiply.
##
## The first two are baked per cell by TerrainBuilder.bake_shade because they
## cost ~50 taps each; the third runs live because it costs four.

## Where the sun is. Upper-left and high is the illustration convention, and it
## is also a performance decision: shadow length is height * cot(elevation), and
## a low sun means re-baking a large neighbourhood for every shovel-load.
@export_range(-180.0, 180.0) var sun_azimuth_deg: float = -50.0
@export_range(10.0, 89.0) var sun_elevation_deg: float = 58.0

## The gradient map. Sampled by the light term, so a single scalar illumination
## value picks a COLOUR rather than a brightness. Author it like a painter:
## cool and dark at 0, a darker-but-MORE-SATURATED occlusion band near 0.2,
## neutral through the middle, warm and pale at 1. The saturation bump is the
## stop that sells it, and it is invisible as a band because its neighbours
## interpolate through it.
##
## Null falls back to plain half-Lambert, which is the grey-box look.
@export var tone_ramp: Gradient
@export_range(0.0, 1.0) var tone_ramp_strength: float = 1.0
## Pushes the terminator. Above 1 widens the lit side, below 1 the shadow side.
@export_range(0.25, 4.0) var terminator_k: float = 1.5

## Ambient occlusion, baked by a horizon sweep.
## The reach is the sensitive number: at 2-3 cells it is a crease and reads as
## dirt, at 6-10 m it is the broad airbrushed darkening the reference has.
@export var ao_reach_m: float = 8.0
@export_range(0.0, 1.0) var ao_strength: float = 0.85
## How much the AO darkens DIRECT light as well as ambient. A painter darkens
## the contact regardless of where the sun is, so this is not zero.
@export_range(0.0, 1.0) var ao_light_affect: float = 0.55

## The cast shadow, marched back along the sun azimuth.
@export var shadow_reach_m: float = 14.0
## Penumbra width in metres — the paint program's Size slider.
@export var shadow_softness_m: float = 2.2
@export_range(0.0, 1.0) var shadow_strength: float = 0.70

## Curvature. `curv_wide_m` is the spacing of the baked broad Laplacian;
## the fine one is always one cell and runs live in the shader.
@export var curv_wide_m: float = 3.0
@export var curv_gain: float = 5.0
## Dark line in every concave crease — where a root meets the ground, where a
## trench floor meets its wall. This is the ink that replaces the band seams.
@export_range(0.0, 1.0) var crease_ink: float = 0.45
## Bright line along every convex crest. Gated by the lit side, so a crest in
## shadow does not glow.
@export_range(0.0, 2.0) var ridge_gain: float = 0.55
@export var ridge_tint: Color = Color(0.80, 0.93, 0.78)

@export_group("Painterly")
## Brush strokes at material level rather than a Kuwahara post-process. See the
## shader for why: Godot's compositor is only half-supported on the Mobile
## renderer, and a Kuwahara kernel is ~50 texture fetches per pixel on a phone
## with no measured headroom. This is three noise evaluations.
##
## Master knob. Zero skips every part of it, including the extra taps.
@export_range(0.0, 1.0) var paint_strength: float = 0.0
## Strokes per metre, and how long each one is against how wide. The stretch is
## what turns round noise into brush marks.
@export var stroke_scale: float = 1.1
@export_range(1.0, 16.0) var stroke_stretch: float = 7.0
@export_range(0.0, 2.0) var stroke_depth: float = 0.60
## Posterise the albedo into this many steps. Zero is off. Smooth gradients are
## the giveaway that a surface was computed rather than mixed.
@export var paint_quantise: float = 0.0
## How far a stroke shifts the colour. This is the half that makes flat ground
## read as painted: bending the normal only shows through the light, and under
## a high sun a plateau top has the same N·L everywhere.
@export_range(0.0, 1.0) var paint_tone: float = 0.35
## The canvas weave under the paint. Sampled unrotated and much finer than the
## strokes, because a weave belongs to the surface, not to the marks on it.
@export_range(0.0, 0.5) var canvas_grain: float = 0.10

@export_group("Ink")
## Outlines, from the depth buffer alone. The usual Godot outline reads the
## normal-roughness buffer, which FAILS TO COMPILE on the Mobile renderer
## (godotengine/godot#78411) — so this is depth-only: first differences for
## silhouettes, second differences for creases.
@export var ink_colour: Color = Color(0.02, 0.05, 0.06)
@export_range(0.0, 1.0) var ink_strength: float = 0.0
@export var ink_silhouette: float = 0.012
@export var ink_crease: float = 0.003
@export var ink_thickness_px: float = 1.3
## Past this, stop inking. Distant ground would otherwise turn into a mesh of
## lines as every metre of relief crosses the threshold inside one pixel.
@export var ink_fade_m: float = 140.0

@export_group("Readability")
## The red line exactly at the impassable threshold. Grey-box readability aid,
## not art: set to 0 for screenshots, back to 0.85 to check a trench actually
## severed the ground.
@export_range(0.0, 1.0) var threshold_line_strength: float = 0.85
