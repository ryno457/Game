class_name GroundMaterial
extends Resource
## One kind of stuff the ground is made of.
##
## The reference map reads as large flat areas of DIFFERENT MATERIAL with hard
## organic borders — moss flats, bare rock, pale sediment at the waterline —
## not as one surface shaded by altitude. Two places at the same height are
## often different materials, which is exactly what a height ramp cannot say.

@export var id: StringName = &""
@export var display_name: String = ""
@export var colour: Color = Color(0.30, 0.36, 0.33)
## Secondary colour the brush strokes mix toward, so a material is two values
## a painter would have mixed rather than one flat fill.
@export var colour_alt: Color = Color(0.36, 0.42, 0.38)
@export_range(0.0, 1.0) var roughness: float = 0.85
## How much of the glowing filament web grows on this material. THIS is what
## keeps the vines at the borders: only the root mat gets a high value, so the
## open flats are clear.
@export_range(0.0, 2.0) var vein_strength: float = 0.0
## Scales the brush stroke size. Rock takes shorter, choppier marks than moss.
@export_range(0.25, 3.0) var stroke_scale_mult: float = 1.0
