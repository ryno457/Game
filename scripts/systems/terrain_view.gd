class_name TerrainView
extends Node3D
## Renders a Heightfield as chunked meshes displaced in the vertex shader.
##
## Rendering only — no physics bodies. Spike A already answered whether
## per-chunk collision holds up; for gameplay the prototype uses a software
## ray march against the heightfield instead, which needs no chunking
## constraints and no collision cook at all.

const CHUNK := Vector2i(25, 28)     ## 150x112 divides into 6 x 4 chunks

var field: Heightfield
var fog: FogOfWar

var _mat: ShaderMaterial
var _tex: ImageTexture
var _dirty := true


func setup(p_field: Heightfield, p_fog: FogOfWar, shader: Shader) -> void:
	field = p_field
	fog = p_fog
	var cfg := field.cfg

	var img := Image.create_empty(cfg.cells_x, cfg.cells_z, false, Image.FORMAT_RF)
	_tex = ImageTexture.create_from_image(img)

	_mat = ShaderMaterial.new()
	_mat.shader = shader
	_mat.set_shader_parameter("height_map", _tex)
	_mat.set_shader_parameter("fog_map", fog.texture())
	_mat.set_shader_parameter("field_size_m",
		Vector2(cfg.cells_x * cfg.cell_size_m, cfg.cells_z * cfg.cell_size_m))
	_mat.set_shader_parameter("height_scale_m", cfg.height_scale_m)
	_mat.set_shader_parameter("texel_m", cfg.cell_size_m)
	_mat.set_shader_parameter("impassable_below", cfg.impassable_below)
	_mat.set_shader_parameter("rough_below", cfg.rough_below)


## Repaint the ground for a biodome. Separate from setup() because the palette
## is a look, not a shape — the same heightfield is the same map whether it is
## lit like a quarry or like the inside of something alive.
func apply_palette(p: BiomePalette) -> void:
	if p == null or _mat == null:
		return
	_mat.set_shader_parameter("col_pool", p.col_pool)
	_mat.set_shader_parameter("col_rough", p.col_rough)
	_mat.set_shader_parameter("col_ground", p.col_ground)
	_mat.set_shader_parameter("col_ridge", p.col_ridge)
	_mat.set_shader_parameter("col_cliff", p.col_cliff)
	_mat.set_shader_parameter("fog_tint", p.fog_tint)
	_mat.set_shader_parameter("pool_glow", p.pool_glow)
	_mat.set_shader_parameter("pool_glow_strength", p.pool_glow_strength)
	_mat.set_shader_parameter("vein_glow", p.vein_glow)
	_mat.set_shader_parameter("vein_strength", p.vein_strength)
	_mat.set_shader_parameter("vein_scale", p.vein_scale)
	_mat.set_shader_parameter("vein_sharpness", p.vein_sharpness)
	_mat.set_shader_parameter("threshold_line_strength", p.threshold_line_strength)
	_mat.set_shader_parameter("detail_strength", p.detail_strength)
	_mat.set_shader_parameter("detail_scale", p.detail_scale)
	_mat.set_shader_parameter("detail_fade_m", p.detail_fade_m)
	_mat.set_shader_parameter("macro_strength", p.macro_strength)
	_mat.set_shader_parameter("macro_scale", p.macro_scale)
	_mat.set_shader_parameter("striation_strength", p.striation_strength)


## Scale the per-fragment surface work without rebuilding the palette. The
## quality preset drives this; zero turns the detail bump off, which is where
## most of the fragment cost lives.
func set_detail_scale_factor(factor: float, p: BiomePalette) -> void:
	if _mat == null or p == null:
		return
	_mat.set_shader_parameter("detail_strength", p.detail_strength * factor)
	_mat.set_shader_parameter("striation_strength", p.striation_strength * factor)
	_mat.set_shader_parameter("detail_fade_m", p.detail_fade_m * maxf(0.35, factor))

	_build_chunks()
	upload()


func _build_chunks() -> void:
	var cfg := field.cfg
	var cs := cfg.cell_size_m
	var nx := cfg.cells_x / CHUNK.x
	var nz := cfg.cells_z / CHUNK.y
	for cz in nz:
		for cx in nx:
			var mesh := PlaneMesh.new()
			mesh.size = Vector2(CHUNK.x * cs, CHUNK.y * cs)
			mesh.subdivide_width = CHUNK.x - 1
			mesh.subdivide_depth = CHUNK.y - 1
			# The shader lifts vertices, so without a custom AABB a chunk gets
			# frustum-culled while still on screen.
			mesh.custom_aabb = AABB(
				Vector3(-CHUNK.x * cs * 0.5, 0.0, -CHUNK.y * cs * 0.5),
				Vector3(CHUNK.x * cs, cfg.height_scale_m, CHUNK.y * cs))
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			mi.material_override = _mat
			mi.position = Vector3(
				(cx * CHUNK.x + CHUNK.x * 0.5) * cs, 0.0,
				(cz * CHUNK.y + CHUNK.y * 0.5) * cs)
			# Terrain both casts and receives: a trench with no shadow in it
			# does not read as a trench, and that legibility is the point.
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			add_child(mi)


func mark_dirty() -> void:
	_dirty = true


func upload() -> void:
	if not _dirty:
		return
	var cfg := field.cfg
	var img := Image.create_from_data(cfg.cells_x, cfg.cells_z, false,
		Image.FORMAT_RF, field.heights.to_byte_array())
	_tex.update(img)
	_dirty = false


## World Y of the terrain surface under a point. Heightfield stores normalized
## heights; the scale lives in TerrainConfig.
func height_at(world_xz: Vector2) -> float:
	return field.height_at(world_xz) * field.cfg.height_scale_m


## March a ray against the heightfield. Boring, allocation-free, and it removes
## the need for any collision geometry at all.
func raycast(from: Vector3, dir: Vector3, max_dist := 400.0) -> Variant:
	var step := field.cfg.cell_size_m * 0.5
	var t := 0.0
	var prev := from
	while t < max_dist:
		t += step
		var p := from + dir * t
		var ground := height_at(Vector2(p.x, p.z))
		if p.y <= ground:
			# Bisect once between the last two samples for a tidy hit point.
			var mid := (prev + p) * 0.5
			mid.y = height_at(Vector2(mid.x, mid.z))
			return mid
		prev = p
	return null
