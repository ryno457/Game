class_name QualityRig
extends RefCounted
## Applies a QualityConfig to a live viewport.
##
## Separate from LightingRig because they answer different questions. Lighting
## is what the game LOOKS like and must be identical everywhere or a frame-rate
## soak measures a game nobody ships. Quality is what the device can AFFORD,
## and is meant to differ between a phone and a desktop.

static func apply(cfg: QualityConfig, viewport: Viewport,
		terrain: TerrainView = null, palette: BiomePalette = null,
		ink: InkPass = null) -> void:
	if cfg == null or viewport == null:
		return
	viewport.msaa_3d = cfg.msaa_3d as Viewport.MSAA
	viewport.screen_space_aa = cfg.screen_space_aa as Viewport.ScreenSpaceAA
	viewport.scaling_3d_scale = cfg.render_scale
	# Bilinear, not FSR. FSR2 is not available on the Mobile renderer, and FSR1
	# on a scene with this much thin high-contrast geometry sharpens the
	# aliasing rather than hiding it.
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR

	# Applied after LightingRig on purpose: shadow cost is a device decision,
	# not a look decision, so the quality preset overrides what the lighting
	# config asked for. See LightingRig._project_quality.
	RenderingServer.directional_shadow_atlas_set_size(cfg.shadow_atlas_size, true)
	RenderingServer.directional_soft_shadow_filter_set_quality(
		cfg.soft_shadow_quality as RenderingServer.ShadowQuality)
	RenderingServer.positional_soft_shadow_filter_set_quality(
		cfg.soft_shadow_quality as RenderingServer.ShadowQuality)

	if terrain != null and palette != null:
		terrain.set_detail_scale_factor(cfg.terrain_detail, palette)
	if ink != null and palette != null:
		ink.set_strength(palette.ink_strength * cfg.ink)
