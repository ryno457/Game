class_name GroundMaterials
extends RefCounted
## The material slots, and the order they sit in the shader's uniform arrays.
##
## Indices rather than names in the heightfield because the map goes to the GPU
## as a texture: one byte per cell, read back as a slot number. Five is the
## whole budget — the shader carries one array entry each and a sixth would
## cost a uniform slot for a distinction the eye would not make from this far up.

const MOSS := 0
const ROCK := 1
const SEDIMENT := 2
const LOAM := 3
const VINE := 4
const COUNT := 5

const NAMES := ["moss", "rock", "sediment", "loam", "vine"]
