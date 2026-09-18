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
## The soft overhead fill, or null when it is switched off.
##
## AreaLight3D is new in Godot 4.7 and the Mobile renderer runs it — eight per
## mesh, the same budget as omnis and spots. That matters here because every
## feature Mobile refuses (SDFGI, VoxelGI, SSIL, SSAO, volumetric fog) is a way
## of getting INDIRECT light, and this is the one new way of getting soft light
## that needs none of them.
##
## The caller adds it to the tree, the same shape as CanopyLight.build, so a
## scene opts in by adding it and nothing else changes.
## `force` builds it even when the config has it off, starting it HIDDEN, so
## the LIGHTS button can switch it on. A light that was never built cannot be
## toggled, and the point of the button is measuring this on a real phone.
static func build_area_fill(cfg: LightingConfig, map_size_m: Vector2,
		floor_y: float, force := false) -> AreaLight3D:
	if not cfg.area_fill_enabled and not force:
		return null
	var a := AreaLight3D.new()
	a.name = "AreaFill"
	a.visible = cfg.area_fill_enabled
	a.position = Vector3(map_size_m.x * 0.5,
		floor_y + cfg.area_fill_height_m, map_size_m.y * 0.5)
	# Face down. An AreaLight3D emits along its local -Z, like a spot.
	a.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	a.area_size = Vector2(map_size_m.x * cfg.area_fill_cover,
		map_size_m.y * cfg.area_fill_cover)
	a.area_range = cfg.area_fill_range_m
	a.area_attenuation = cfg.area_fill_attenuation
	a.light_color = cfg.area_fill_colour
	a.light_energy = cfg.area_fill_energy
	# NO SHADOWS. A second shadow-casting light is the single most expensive
	# thing on this renderer, and a fill that casts shadows is not a fill — it
	# competes with the moon and the frame reads as two suns.
	a.shadow_enabled = false
	return a


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


## The sun's direction over the ground, normalised: which way the light comes
## FROM, flattened to the XZ plane.
##
## The ravine wall needs this to know which flank the moon reaches. It is
## derived from the same light the rig builds rather than typed beside it, for
## the reason sun_angles() exists at all: the shadow bake and the light already
## disagreed once, and the fix was to stop writing the number twice.
static func sun_ground_dir(cfg: LightingConfig) -> Vector2:
	var az := deg_to_rad(sun_angles(cfg).x)
	return Vector2(sin(az), -cos(az)).normalized()


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
