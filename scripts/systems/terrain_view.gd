class_name TerrainView
extends Node3D
## Renders a Heightfield as chunked meshes displaced in the vertex shader.
##
## Rendering only — no physics bodies. Spike A already answered whether
## per-chunk collision holds up; for gameplay the prototype uses a software
## ray march against the heightfield instead, which needs no chunking
## constraints and no collision cook at all.

## 150 x 112 divides into 6 x 4 chunks.
const CHUNK := Vector2i(25, 28)
## Entries in the tone-ramp LUT. 256 with linear filtering resolves finer than
## the render buffer, so the ramp can never itself be the source of a band.
const RAMP_WIDTH := 256
## The project's first texture asset. See the shader for the channel packing.
const BRUSH_TEX := "res://textures/brush_strokes.png"

var field: Heightfield
var fog: FogOfWar

var _mat: ShaderMaterial
var _tex: ImageTexture
## Uploaded once. See Heightfield.water: digging changes heights every frame
## and never creates a lake.
var _water_tex: ImageTexture
var _material_tex: ImageTexture
var _field_tex: ImageTexture
var _shade_tex: ImageTexture
var _dirty := true


func setup(p_field: Heightfield, p_fog: FogOfWar, shader: Shader) -> void:
	field = p_field
	fog = p_fog
	var cfg := field.cfg

	var img := Image.create_empty(cfg.cells_x, cfg.cells_z, false, Image.FORMAT_RF)
	_tex = ImageTexture.create_from_image(img)

	_mat = ShaderMaterial.new()
	_mat.shader = shader
	var wimg := Image.create_from_data(cfg.cells_x, cfg.cells_z, false,
		Image.FORMAT_RF, p_field.water.to_byte_array())
	_water_tex = ImageTexture.create_from_image(wimg)

	_mat.set_shader_parameter("height_map", _tex)
	_mat.set_shader_parameter("water_map", _water_tex)

	# The material and distance maps are NOT uploaded here. Both depend on the
	# materials having been classified, and classification needs thresholds
	# that live on the palette — which setup() has not been given. They upload
	# in apply_palette instead, which runs after the caller has classified.
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
	_mat.set_shader_parameter("bio_pool_gain", p.bio_pool_gain)
	_mat.set_shader_parameter("bio_pool_reach_m", p.bio_pool_reach_m)
	_mat.set_shader_parameter("bio_root_gain", p.bio_root_gain)
	_mat.set_shader_parameter("bio_root_reach_m", p.bio_root_reach_m)
	_mat.set_shader_parameter("threshold_line_strength", p.threshold_line_strength)
	_mat.set_shader_parameter("detail_strength", p.detail_strength)
	_mat.set_shader_parameter("detail_albedo", p.detail_albedo)
	_mat.set_shader_parameter("detail_scale", p.detail_scale)
	_mat.set_shader_parameter("detail_fade_m", p.detail_fade_m)
	_mat.set_shader_parameter("macro_strength", p.macro_strength)
	_mat.set_shader_parameter("macro_scale", p.macro_scale)
	_mat.set_shader_parameter("striation_strength", p.striation_strength)
	_mat.set_shader_parameter("void_below", p.void_below)
	_mat.set_shader_parameter("grid_spacing_m", p.grid_spacing_m)
	_mat.set_shader_parameter("grid_colour", p.grid_colour)
	_mat.set_shader_parameter("grid_strength", p.grid_strength)
	_mat.set_shader_parameter("grid_width_px", p.grid_width_px)
	_mat.set_shader_parameter("pool_glow_alt", p.pool_glow_alt)
	_mat.set_shader_parameter("pool_alt_mix", p.pool_alt_mix)
	_mat.set_shader_parameter("paint_strength", p.paint_strength)
	_mat.set_shader_parameter("stroke_scale", p.stroke_scale)
	_mat.set_shader_parameter("stroke_stretch", p.stroke_stretch)
	_mat.set_shader_parameter("stroke_depth", p.stroke_depth)
	_mat.set_shader_parameter("paint_quantise", p.paint_quantise)
	_mat.set_shader_parameter("paint_tone", p.paint_tone)
	_mat.set_shader_parameter("canvas_grain", p.canvas_grain)
	_mat.set_shader_parameter("brush_tex", load(BRUSH_TEX))
	_apply_materials(p)


## Unpack the material slots into the shader's parallel uniform arrays.
##
## A short array of small arrays rather than one array of structs, because GLSL
## uniform arrays of structs are awkward to set from GDScript and this is five
## entries — the unpacking is cheaper than the abstraction.
func _apply_materials(p: BiomePalette) -> void:
	var cols := PackedColorArray()
	var alts := PackedColorArray()
	var rough := PackedFloat32Array()
	var vein := PackedFloat32Array()
	var stroke := PackedFloat32Array()
	for i in GroundMaterials.COUNT:
		var m: GroundMaterial = p.materials[i] if i < p.materials.size() else null
		if m == null:
			# A missing slot must be visible, not silently black: an index the
			# classifier emits with nothing behind it is a build error.
			push_warning("palette has no material for slot %d (%s)"
				% [i, GroundMaterials.NAMES[i]])
			m = GroundMaterial.new()
			m.colour = Color.MAGENTA
			m.colour_alt = Color.MAGENTA
		cols.append(m.colour)
		alts.append(m.colour_alt)
		rough.append(m.roughness)
		vein.append(m.vein_strength)
		stroke.append(m.stroke_scale_mult)
	_mat.set_shader_parameter("mat_colour", cols)
	_mat.set_shader_parameter("mat_colour_alt", alts)
	_mat.set_shader_parameter("mat_rough", rough)
	_mat.set_shader_parameter("mat_vein", vein)
	_mat.set_shader_parameter("mat_stroke", stroke)
	_mat.set_shader_parameter("material_jitter_m", p.material_jitter_m)
	_mat.set_shader_parameter("material_jitter_scale", p.material_jitter_scale)
	_mat.set_shader_parameter("field_range_m", p.field_range_m)
	_mat.set_shader_parameter("edge_shade", p.edge_shade)
	_mat.set_shader_parameter("edge_falloff_m", p.edge_falloff_m)
	_mat.set_shader_parameter("strand_shade", p.strand_shade)
	_mat.set_shader_parameter("strand_falloff_m", p.strand_falloff_m)
	_mat.set_shader_parameter("strand_range_m", p.strand_range_m)
	_mat.set_shader_parameter("shore_pale", p.shore_pale)
	_mat.set_shader_parameter("shore_falloff_m", p.shore_falloff_m)
	_mat.set_shader_parameter("tube_radius_m", p.tube_radius_m)
	_mat.set_shader_parameter("tube_blend", p.tube_blend)
	_mat.set_shader_parameter("ao_strength", p.ao_strength)
	_mat.set_shader_parameter("ao_light_affect", p.ao_light_affect)
	_mat.set_shader_parameter("shadow_strength", p.shadow_strength)
	_mat.set_shader_parameter("terminator_k", p.terminator_k)
	_mat.set_shader_parameter("curv_gain", p.curv_gain)
	_mat.set_shader_parameter("curv_range", TerrainBuilder.CURV_RANGE)
	_mat.set_shader_parameter("crease_ink", p.crease_ink)
	_mat.set_shader_parameter("ridge_gain", p.ridge_gain)
	_mat.set_shader_parameter("ridge_tint", p.ridge_tint)
	_mat.set_shader_parameter("tone_ramp", _ramp_texture(p))
	_mat.set_shader_parameter("tone_ramp_strength",
		p.tone_ramp_strength if p.tone_ramp != null else 0.0)
	_upload_maps(p)


## The gradient map as a 256x1 texture.
##
## Built from the palette's Gradient rather than shipped as an image, so the
## whole lighting model stays art-editable in the .tres and nothing here is an
## asset. 256 entries with linear filtering quantises finer than the render
## buffer can represent, so the ramp itself can never be the source of a band.
func _ramp_texture(p: BiomePalette) -> Texture2D:
	if p.tone_ramp == null:
		return null
	var t := GradientTexture1D.new()
	t.gradient = p.tone_ramp
	t.width = RAMP_WIDTH
	# HDR, and it is not optional now. The ramp is built from the reference's own
	# value ramp normalised so its commonest value is unity, which puts the
	# bright end at 2.98 — an 8-bit gradient texture would clamp every stop past
	# the middle to 1.0 and flatten the top half of the ramp into one value.
	#
	# It also means the ramp is authored in the shader's own linear space rather
	# than sRGB, which is what the hue path needs.
	t.use_hdr = true
	return t


## Material ids and the distance fields, uploaded once.
##
## Here rather than in setup() because both depend on the caller having already
## run TerrainBuilder.classify_materials — the strand field is distance to the
## VINE material, so the materials have to exist before the field can be baked.
## Neither changes per frame: digging changes the SHAPE of the ground, not what
## it is made of, and the fields only shift near a dig.
func _upload_maps(p: BiomePalette) -> void:
	if field == null or _mat == null:
		return
	var cfg := field.cfg
	var mimg := Image.create_from_data(cfg.cells_x, cfg.cells_z, false,
		Image.FORMAT_R8, field.material_id)
	_material_tex = ImageTexture.create_from_image(mimg)
	_mat.set_shader_parameter("material_map", _material_tex)

	var fimg := Image.create_from_data(cfg.cells_x, cfg.cells_z, false,
		Image.FORMAT_RGB8,
		TerrainBuilder.bake_fields(field, p.void_below, p.field_range_m,
			p.strand_range_m))
	_field_tex = ImageTexture.create_from_image(fimg)
	_mat.set_shader_parameter("field_map", _field_tex)

	# AO, cast shadow and wide curvature. Unlike the two above, this one DOES
	# change when the ground does — it is a function of the heightfield — so
	# when deformation lands it re-bakes per dirty chunk, dilated by the AO
	# reach and the shadow length. Whole-map here because the map is one mesh.
	var simg := Image.create_from_data(cfg.cells_x, cfg.cells_z, false,
		Image.FORMAT_RGB8, TerrainBuilder.bake_shade(field, p))
	_shade_tex = ImageTexture.create_from_image(simg)
	_mat.set_shader_parameter("shade_map", _shade_tex)


## Scale the per-fragment surface work without rebuilding the palette. The
## quality preset drives this; zero turns the detail bump off, which is where
## most of the fragment cost lives.
func set_detail_scale_factor(factor: float, p: BiomePalette) -> void:
	if _mat == null or p == null:
		return
	_mat.set_shader_parameter("detail_strength", p.detail_strength * factor)
	_mat.set_shader_parameter("striation_strength", p.striation_strength * factor)
	_mat.set_shader_parameter("detail_fade_m", p.detail_fade_m * maxf(0.35, factor))
	# The strokes are the other half of the per-fragment bill: three noise
	# evaluations on top of the detail bump's two. A Low preset drops both.
	_mat.set_shader_parameter("paint_strength", p.paint_strength * factor)

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
