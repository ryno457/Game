class_name QualityConfig
extends Resource
## Render quality, as data.
##
## This project has NO TEXTURES — no image files, no UVs on any mesh — so none
## of the usual quality levers exist: there is no mipmap bias to tune, no
## anisotropy to raise, no albedo resolution to double. What there is instead:
##
##   · antialiasing, which matters more here than in a textured game because
##     untextured low-poly art is nothing BUT silhouette, and every arch strut
##     and coral branch is a thin high-contrast edge against a dark ground
##   · render scale, the blunt instrument
##   · how much procedural surface the terrain shader computes per fragment
##   · shadow resolution and softness
##
## Two presets ship. The point of having both is not to give the player a
## settings menu — it is so the phone test can measure what the expensive one
## actually costs, on the device, instead of guessing.

@export var display_name: String = ""

@export_group("Antialiasing")
## The big one for this art style. On a tile-based mobile GPU MSAA resolves in
## tile memory, so 2x is far cheaper here than the same setting would be on a
## desktop deferred renderer — but it is not free, and 4x on a 1080x2400 phone
## is a real bill.
@export_enum("Off:0", "2x:1", "4x:2", "8x:3") var msaa_3d: int = 1
## FXAA. Cheap, blurry, and catches the edges MSAA misses (shader aliasing on
## the terrain's threshold line, the emissive pool shoreline).
@export_enum("Off:0", "FXAA:1") var screen_space_aa: int = 0

@export_group("Resolution")
## Render 3D at this fraction of the screen and upscale. Below about 0.8 the
## thin silhouettes this art is made of start to break up, which is the exact
## thing MSAA was added to fix — so this is the last knob to reach for, not
## the first.
@export_range(0.5, 1.0) var render_scale: float = 1.0

@export_group("Surface")
## Multiplies the terrain's detail bump and striation. Zero skips the two extra
## noise taps per fragment entirely, which is most of what the low preset saves.
@export_range(0.0, 2.0) var terrain_detail: float = 1.0

## Outlines. A screen-reading pass forces a resolve on a tile-based mobile GPU
## — it breaks tiling — so this is the one effect whose cost is structural
## rather than proportional to how much of it there is. Off on Low so the
## phone can say what it costs.
@export_range(0.0, 1.0) var ink: float = 1.0

@export_group("Shadows")
@export var shadow_atlas_size: int = 2048
@export_enum("Hard:0", "Soft Very Low:1", "Soft Low:2", "Soft Medium:3", "Soft High:4", "Soft Ultra:5")
var soft_shadow_quality: int = 2
