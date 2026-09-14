class_name LightingRig
extends RefCounted
## Applies a LightingConfig to a live scene.
##
## Built as code rather than baked into a .tscn so the spike and the prototype
## get the SAME lighting from one source. A frame-rate soak lit differently
## from the game measures a game nobody ships.

static func apply(cfg: LightingConfig, sun: DirectionalLight3D,
		world: WorldEnvironment) -> void:
	_sun(cfg, sun)
	world.environment = build_environment(cfg)
	_project_quality(cfg)


static func _sun(cfg: LightingConfig, sun: DirectionalLight3D) -> void:
	sun.rotation_degrees = cfg.sun_rotation_deg
	sun.light_color = cfg.sun_colour
	sun.light_energy = cfg.sun_energy
	sun.light_specular = cfg.sun_specular
	sun.shadow_enabled = cfg.shadows_enabled
	sun.directional_shadow_mode = cfg.shadow_mode as DirectionalLight3D.ShadowMode
	sun.directional_shadow_max_distance = cfg.shadow_max_distance
	sun.directional_shadow_split_1 = cfg.shadow_split_1
	sun.directional_shadow_fade_start = cfg.shadow_fade_start
	sun.shadow_normal_bias = cfg.shadow_normal_bias
	sun.shadow_bias = cfg.shadow_bias
	sun.shadow_blur = cfg.shadow_blur


static func build_environment(cfg: LightingConfig) -> Environment:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = cfg.sky_top
	sky_mat.sky_horizon_color = cfg.sky_horizon
	sky_mat.ground_horizon_color = cfg.ground_horizon
	sky_mat.ground_bottom_color = cfg.ground_bottom
	sky_mat.sun_angle_max = 22.0
	sky_mat.sun_curve = 0.16
	sky_mat.energy_multiplier = cfg.sky_energy

	var sky := Sky.new()
	sky.sky_material = sky_mat
	# REALTIME would re-render the sky every frame for a sky that never moves.
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	sky.radiance_size = Sky.RADIANCE_SIZE_128

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_color = cfg.ambient_colour
	env.ambient_light_sky_contribution = cfg.ambient_sky_contribution
	env.ambient_light_energy = cfg.ambient_energy
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY

	env.tonemap_mode = cfg.tonemap as Environment.ToneMapper
	env.tonemap_exposure = cfg.tonemap_exposure
	env.tonemap_white = cfg.tonemap_white

	env.fog_enabled = cfg.fog_enabled
	env.fog_light_color = cfg.fog_colour
	env.fog_density = cfg.fog_density
	env.fog_sky_affect = cfg.fog_sky_affect
	env.fog_height_density = cfg.fog_height_falloff

	env.glow_enabled = cfg.glow_enabled
	env.glow_hdr_threshold = cfg.glow_hdr_threshold
	env.glow_strength = cfg.glow_strength
	env.glow_bloom = cfg.glow_bloom

	# Not available on the Mobile renderer — set explicitly so nobody wonders
	# whether they were forgotten.
	env.sdfgi_enabled = false
	env.ssao_enabled = false
	env.ssil_enabled = false
	env.volumetric_fog_enabled = false
	return env


## Project-wide quality knobs. These are RenderingServer settings, not scene
## properties, so they apply to whatever is rendering.
static func _project_quality(cfg: LightingConfig) -> void:
	RenderingServer.directional_shadow_atlas_set_size(cfg.shadow_atlas_size, true)
	RenderingServer.directional_soft_shadow_filter_set_quality(
		cfg.soft_shadow_quality as RenderingServer.ShadowQuality)
	RenderingServer.positional_soft_shadow_filter_set_quality(
		cfg.soft_shadow_quality as RenderingServer.ShadowQuality)
