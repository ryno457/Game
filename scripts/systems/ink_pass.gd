class_name InkPass
extends MeshInstance3D
## The full-screen quad the outline shader runs on.
##
## A MeshInstance3D rather than a CanvasLayer + ColorRect, because the depth
## texture is not available to canvas_item shaders — reading it there breaks
## code generation (godotengine/godot#74464). A spatial shader on a quad
## written straight to clip space is the route the engine's own advanced
## post-processing tutorial takes, and it works on both renderers.

const SHADER := "res://shaders/outline.gdshader"


static func build() -> InkPass:
	var pass_node := InkPass.new()
	pass_node.name = "InkPass"
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	pass_node.mesh = quad
	# The vertex function ignores the transform entirely, so the quad must never
	# be culled for being somewhere the camera is not looking.
	pass_node.extra_cull_margin = 16384.0
	pass_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pass_node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	# Drawn after everything opaque, so the screen texture it reads is the
	# finished frame rather than half of one.
	pass_node.sorting_offset = 1000.0

	var mat := ShaderMaterial.new()
	mat.shader = load(SHADER)
	mat.render_priority = 100
	pass_node.material_override = mat
	return pass_node


func apply(p: BiomePalette) -> void:
	var mat := material_override as ShaderMaterial
	if mat == null or p == null:
		return
	mat.set_shader_parameter("ink_colour", p.ink_colour)
	mat.set_shader_parameter("ink_strength", p.ink_strength)
	mat.set_shader_parameter("silhouette_threshold", p.ink_silhouette)
	mat.set_shader_parameter("crease_threshold", p.ink_crease)
	mat.set_shader_parameter("thickness_px", p.ink_thickness_px)
	mat.set_shader_parameter("fade_m", p.ink_fade_m)


## Scale the ink without rebuilding the palette, for the quality preset.
func set_strength(v: float) -> void:
	var mat := material_override as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter("ink_strength", v)
