class_name LightingConfig
extends Resource
## Final-quality lighting, as data.
##
## This exists because measuring frame rate without it measures nothing: the
## shipped game renders shadows and a lit sky, so a soak run that skips them
## reports a number the player will never see. Every value here is chosen
## against the Mobile renderer's actual limits.
##
## Mobile renderer constraints that shaped these:
##   - no SDFGI, no volumetric fog, no SSIL, no screen-space reflections
##   - one directional shadow is affordable; more are not
##   - shadow atlas size is the single biggest lighting cost lever
##   - ambient comes from the sky, not from a global illumination bake, because
##     the terrain deforms at runtime and cannot be baked

@export_group("Sun")
@export var sun_rotation_deg: Vector3 = Vector3(-38.0, -132.0, 0.0)
@export var sun_colour: Color = Color(1.0, 0.91, 0.78)
@export var sun_energy: float = 1.45
@export var sun_specular: float = 0.35

@export_group("Shadows")
@export var shadows_enabled: bool = true
## PSSM 2-split: enough depth range for an RTS camera without paying for 4.
@export_enum("Orthogonal:0", "PSSM 2 Splits:1", "PSSM 4 Splits:2")
var shadow_mode: int = 1
## Beyond this, shadows stop. Tight on purpose — an RTS camera sees far, but
## shadows past the play area are invisible and cost real milliseconds.
@export var shadow_max_distance: float = 85.0
@export var shadow_split_1: float = 0.12
@export var shadow_fade_start: float = 0.85
@export var shadow_normal_bias: float = 1.4
@export var shadow_bias: float = 0.04
@export var shadow_blur: float = 1.0
## Directional shadow atlas, in pixels. The dominant lighting cost.
@export var shadow_atlas_size: int = 2048
@export_enum("Hard:0", "Soft Very Low:1", "Soft Low:2", "Soft Medium:3", "Soft High:4", "Soft Ultra:5")
var soft_shadow_quality: int = 2

@export_group("Sky and ambient")
@export var sky_top: Color = Color(0.085, 0.115, 0.20)
@export var sky_horizon: Color = Color(0.34, 0.27, 0.27)
@export var ground_horizon: Color = Color(0.20, 0.17, 0.18)
@export var ground_bottom: Color = Color(0.045, 0.045, 0.06)
@export var sky_energy: float = 1.0
@export var ambient_sky_contribution: float = 0.7
@export var ambient_colour: Color = Color(0.40, 0.47, 0.62)
@export var ambient_energy: float = 0.85

@export_group("Atmosphere")
@export var fog_enabled: bool = true
@export var fog_colour: Color = Color(0.09, 0.11, 0.17)
@export var fog_density: float = 0.0032
@export var fog_sky_affect: float = 0.35
@export var fog_height_falloff: float = 0.22

@export_group("Tonemap")
@export_enum("Linear:0", "Reinhard:1", "Filmic:2", "ACES:3") var tonemap: int = 3
@export var tonemap_exposure: float = 1.0
@export var tonemap_white: float = 5.0
@export var glow_enabled: bool = true
## Only the cyan machine emissives should bloom, not the terrain.
@export var glow_hdr_threshold: float = 1.1
@export var glow_strength: float = 0.9
@export var glow_bloom: float = 0.12
