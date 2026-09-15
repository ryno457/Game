class_name CloudSea
extends MeshInstance3D
## One plane of weather under the map.
##
## Built in code rather than placed in the scene for the same reason the
## lighting is: the spike, the preview and the game must all be able to get the
## same deck from one resource, and a .tscn copy would silently rot.

const SHADER := "res://shaders/cloud_sea.gdshader"


static func build(cfg: CloudConfig) -> CloudSea:
	var deck := CloudSea.new()
	deck.name = "CloudSea"
	var plane := PlaneMesh.new()
	plane.size = Vector2(cfg.extent_m * 2.0, cfg.extent_m * 2.0)
	# One quad. Nothing here needs geometry — the whole deck is a fragment
	# program, and subdividing would only add vertices for the same picture.
	plane.subdivide_width = 0
	plane.subdivide_depth = 0
	deck.mesh = plane
	deck.position.y = cfg.height_m

	var mat := ShaderMaterial.new()
	mat.shader = load(SHADER)
	deck.material_override = mat
	# Never casts: it is below everything, and a shadow-casting plane this size
	# would fill the atlas by itself. Never receives GI either.
	deck.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	deck.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	deck.apply(cfg)
	return deck


func apply(cfg: CloudConfig) -> void:
	var mat := material_override as ShaderMaterial
	if mat == null or cfg == null:
		return
	position.y = cfg.height_m
	mat.set_shader_parameter("lit_colour", cfg.lit_colour)
	mat.set_shader_parameter("shadow_colour", cfg.shadow_colour)
	mat.set_shader_parameter("deep_colour", cfg.deep_colour)
	mat.set_shader_parameter("horizon_colour", cfg.horizon_colour)
	mat.set_shader_parameter("cloud_scale", cfg.cloud_scale)
	mat.set_shader_parameter("coverage", cfg.coverage)
	mat.set_shader_parameter("softness", cfg.softness)
	mat.set_shader_parameter("scroll_mps", cfg.scroll_mps)
	mat.set_shader_parameter("relief", cfg.relief)
	mat.set_shader_parameter("fade_start_m", cfg.fade_start_m)
	mat.set_shader_parameter("fade_end_m", cfg.fade_end_m)
