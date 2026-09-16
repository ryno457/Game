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


## The sun's direction as an (azimuth, elevation) pair in degrees.
##
## One source for the sun, because there were three. The DirectionalLight3D
## takes a Godot Euler triple; TerrainBuilder.bake_shade wants an azimuth and an
## elevation to march cast shadows along; the Blender previews had a hand-typed
## rotation of their own. They had all drifted apart — the light in the scene
## was at azimuth -48 / elevation 38 while the shadows baked into the ground
## were marched at -50 / 42. Nothing on screen says that: shadows pointing four
## degrees wrong still look exactly like shadows.
##
## Azimuth is measured clockwise from -Z, matching bake_shade, and elevation is
## degrees above the horizon. Derived from the light rather than typed beside
## it, so the two cannot disagree again.
static func sun_angles(cfg: LightingConfig) -> Vector2:
	var basis := Basis.from_euler(
		Vector3(deg_to_rad(cfg.sun_rotation_deg.x),
			deg_to_rad(cfg.sun_rotation_deg.y),
			deg_to_rad(cfg.sun_rotation_deg.z)))
	# A DirectionalLight3D shines along its local -Z, so the direction TOWARD
	# the sun is the negative of the direction the light travels.
	var toward := -(basis * Vector3(0.0, 0.0, -1.0))
	return Vector2(rad_to_deg(atan2(toward.x, -toward.z)),
		rad_to_deg(asin(clampf(toward.y, -1.0, 1.0))))


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
##
## QualityRig SETS THE SAME TWO and runs after this in the game, so in the game
## the quality preset wins — deliberately, because shadow cost is a device
## decision and everything else in LightingConfig is a look decision. These
## stay here because Spike A has its own copy of this file and no QualityRig;
## removing them would quietly drop the spike's shadow settings. The precedence
## is asserted in tools/quality_check.gd rather than left as a comment.
static func _project_quality(cfg: LightingConfig) -> void:
	RenderingServer.directional_shadow_atlas_set_size(cfg.shadow_atlas_size, true)
	RenderingServer.directional_soft_shadow_filter_set_quality(
		cfg.soft_shadow_quality as RenderingServer.ShadowQuality)
	RenderingServer.positional_soft_shadow_filter_set_quality(
		cfg.soft_shadow_quality as RenderingServer.ShadowQuality)
