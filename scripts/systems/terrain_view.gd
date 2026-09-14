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
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
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
