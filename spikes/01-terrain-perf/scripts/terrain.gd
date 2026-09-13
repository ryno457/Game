class_name SpikeTerrain
extends Node3D
## Chunked terrain: one shared displaced material for rendering, one
## HeightMapShape3D per chunk for collision.
##
## Rendering cost is fixed — the GPU displaces a static grid every frame no
## matter what changes. The variable cost, and the one that decides this spike,
## is re-cooking collision for the chunks a dig touched.

const CHUNK_BUDGET_MS := 6.0    ## stop re-cooking past this; the rest waits a frame

var field: DeformField
var impassable_below := 0.26
var rough_below := 0.38

var _mat: ShaderMaterial
var _tex: ImageTexture
var _img: Image
var _bodies: Dictionary = {}     # Vector2i -> CollisionShape3D
var _shapes: Dictionary = {}     # Vector2i -> HeightMapShape3D
var _pending: Array[Vector2i] = []

# Cost attribution for the probe, in milliseconds, reset each frame.
var last_texture_ms := 0.0
var last_collision_ms := 0.0
var last_chunks_rebuilt := 0
var backlog := 0


func setup(p_field: DeformField, shader: Shader) -> void:
	field = p_field
	var s := field.samples()

	_img = Image.create_empty(s.x, s.y, false, Image.FORMAT_RF)
	_tex = ImageTexture.create_from_image(_img)

	_mat = ShaderMaterial.new()
	_mat.shader = shader
	_mat.set_shader_parameter("height_map", _tex)
	_mat.set_shader_parameter("field_size_m", field.extent_m())
	_mat.set_shader_parameter("height_scale_m", field.height_scale_m)
	_mat.set_shader_parameter("impassable_below", impassable_below)
	_mat.set_shader_parameter("rough_below", rough_below)
	_mat.set_shader_parameter("texel_m", field.cell_size)

	_build_chunks()
	upload_texture()
	# Cook every chunk once up front so the soak measures steady state, not
	# first-frame warmup.
	for cz in field.chunks.y:
		for cx in field.chunks.x:
			_rebuild_chunk(Vector2i(cx, cz))
	field.dirty.clear()


func _build_chunks() -> void:
	var n := field.chunk_cells
	var cs := field.cell_size
	for cz in field.chunks.y:
		for cx in field.chunks.x:
			var key := Vector2i(cx, cz)
			var centre := Vector3((cx * n + n * 0.5) * cs, 0.0, (cz * n + n * 0.5) * cs)

			var mesh := PlaneMesh.new()
			mesh.size = Vector2(n * cs, n * cs)
			mesh.subdivide_width = n - 1
			mesh.subdivide_depth = n - 1
			# The shader pushes vertices up to height_scale_m; without a
			# custom AABB the chunk gets frustum-culled while still on screen.
			mesh.custom_aabb = AABB(
				Vector3(-n * cs * 0.5, 0.0, -n * cs * 0.5),
				Vector3(n * cs, field.height_scale_m, n * cs))

			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			mi.material_override = _mat
			mi.position = centre
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(mi)

			var shape := HeightMapShape3D.new()
			shape.map_width = n + 1
			shape.map_depth = n + 1

			var col := CollisionShape3D.new()
			col.shape = shape
			var body := StaticBody3D.new()
			body.position = centre
			body.add_child(col)
			add_child(body)

			_shapes[key] = shape
			_bodies[key] = col


## Re-upload the whole height texture. 161x129 R32F is ~83 KB — small enough
## that a partial update is not worth the complexity, but it IS measured
## separately in case that assumption is wrong on a real device.
func upload_texture() -> void:
	var t0 := Time.get_ticks_usec()
	var s := field.samples()
	_img = Image.create_from_data(s.x, s.y, false, Image.FORMAT_RF,
		field.heights.to_byte_array())
	_tex.update(_img)
	last_texture_ms = (Time.get_ticks_usec() - t0) / 1000.0


func _rebuild_chunk(key: Vector2i) -> void:
	var shape: HeightMapShape3D = _shapes[key]
	shape.map_data = field.chunk_collision_data(key.x, key.y)


## Drain the dirty set under a time budget. Chunks that do not fit stay queued;
## `backlog` is the honest signal that the device cannot keep up with digging.
func flush(dirty_this_frame: bool) -> void:
	last_collision_ms = 0.0
	last_chunks_rebuilt = 0

	if dirty_this_frame:
		upload_texture()
	else:
		last_texture_ms = 0.0

	for key in field.dirty:
		if not _pending.has(key):
			_pending.append(key)
	field.dirty.clear()

	var t0 := Time.get_ticks_usec()
	while not _pending.is_empty():
		_rebuild_chunk(_pending.pop_front())
		last_chunks_rebuilt += 1
		if (Time.get_ticks_usec() - t0) / 1000.0 >= CHUNK_BUDGET_MS:
			break
	last_collision_ms = (Time.get_ticks_usec() - t0) / 1000.0
	backlog = _pending.size()
