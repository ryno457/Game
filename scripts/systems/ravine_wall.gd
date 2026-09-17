class_name RavineWall
extends Node3D
## The mountain ravine around and under the map.
##
## Built in code from one resource, for the same reason the lighting and the
## old cloud deck were: the game, the preview and the screenshot tool all have
## to get the same surround, and a .tscn copy of it would silently rot.
##
## TWO PIECES, and both are needed.
##
##   FLOOR   a coarse plane under the whole map. The terrain shader discards
##           every fragment below `void_below`, so the map is full of holes —
##           the two notches in the outline, the channels, the whole surround.
##           Something has to be visible through them or the player sees the
##           clear colour. This is that something, and it is the bottom of the
##           cleft.
##   RING    a band outside the map frame that stays at floor height for
##           `floor_width_m` and then climbs to the crest. The flat part is the
##           chasm; the climb is the wall.
##
## Lit by painted_prop.gdshader — the SAME light() the ground and the machines
## use. Two lighting models in one frame is the bug this project already paid
## for once: the moon rig was tuned against the terrain's tone ramp and
## everything not running that ramp came out roughly its gain too dark.
##
## Cost: about 9k triangles for the whole surround, in two draw calls. The old
## cloud deck was two triangles and a four-octave fbm over most of the screen,
## so this is not obviously the more expensive of the two.

const SHADER := "res://shaders/painted_prop.gdshader"
const ROCK_N := "res://textures/rock_detail_n.png"
const ROCK_AO := "res://textures/rock_detail_ao.png"

var tris := 0


static func build(cfg: RavineConfig, map_size_m: Vector2, ramp: Texture2D,
		sun_dir: Vector2 = Vector2(0.74, 0.67)) -> RavineWall:
	var w := RavineWall.new()
	w.name = "RavineWall"
	var rng := RandomNumberGenerator.new()
	rng.seed = cfg.seed
	var mat := w._material(cfg, ramp)

	w.add_child(w._piece("RavineFloor", w._floor_mesh(cfg, map_size_m), mat))
	w.add_child(w._piece("RavineRing",
		w._ring_mesh(cfg, map_size_m, sun_dir.normalized()), mat))
	return w


func _piece(node_name: String, mesh: ArrayMesh, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.material_override = mat
	tris += mesh.get_faces().size() / 3
	# Never casts. A shadow caster this size fills the atlas by itself, and it
	# is outside everything that could receive the shadow anyway.
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	return mi


func _material(cfg: RavineConfig, ramp: Texture2D) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(SHADER)
	# ONE NUMBER FOR THE WHOLE SURROUND'S LEVEL, and the gradient in COLOR_0.
	#
	# The vertex colours carry the cleft-to-crest ramp and nothing else; this
	# sets how bright the range is against the ground. Splitting it that way is
	# not tidiness — COLOR_0 is EIGHT BITS per channel, and it is a MULTIPLIER
	# on an albedo that is itself a multiplier on a dim moon rig. The first
	# version wrote colours converted to linear, which put the cleft floor at
	# 0.002; it quantised to zero and rendered pure black, which looks exactly
	# like geometry that is not being drawn at all. Everything about this mesh
	# was suspected before the colour was: the winding, the culling, the
	# normals, the material. What actually proved it was setting emission and
	# watching the surround come back magenta while the lit path stayed dark.
	mat.set_shader_parameter("albedo", cfg.wall_albedo)
	mat.set_shader_parameter("use_vertex_colour", true)
	mat.set_shader_parameter("tone_ramp", ramp)
	mat.set_shader_parameter("roughness_v", 0.94)
	# No rim ink. The facing-ratio outline is drawn around a FORM; on a mesh
	# that fills the horizon every distant slope is at a grazing angle and the
	# whole surround would go dark.
	mat.set_shader_parameter("rim_ink", 0.0)
	# THE ROCK. One tiling map over the whole surround, sampled off the UVs the
	# meshes already carry (world metres / rock_tile_m, see _floor_mesh). The
	# ravine is 5600 flat triangles over half a kilometre, so without this its
	# surface is whatever the fog leaves of a smooth slope, which at this
	# distance is nothing. Generated rather than baked: rock at half a metre is
	# fractal and the same everywhere, so modelling it would be modelling noise.
	var n: Texture2D = load(ROCK_N) if ResourceLoader.exists(ROCK_N) else null
	var ao: Texture2D = load(ROCK_AO) if ResourceLoader.exists(ROCK_AO) else null
	if n != null and ao != null and cfg.wall_detail > 0.0:
		mat.set_shader_parameter("detail_n", n)
		mat.set_shader_parameter("detail_ao", ao)
		mat.set_shader_parameter("detail_strength", cfg.wall_detail)
		mat.set_shader_parameter("detail_ao_strength", cfg.wall_detail_ao)
	else:
		mat.set_shader_parameter("detail_strength", 0.0)
	return mat


# --- the shape --------------------------------------------------------------
## Height of the wall at `s` metres outward from the map frame, and how far up
## the climb that is (0 on the floor, 1 at the crest).
func _wall_y(cfg: RavineConfig, s: float, along: float, out_d: float) -> Vector2:
	var floor_y := cfg.floor_y_m + _fbm(along * 0.06, out_d * 0.06) * cfg.floor_relief_m
	if s <= cfg.floor_width_m:
		return Vector2(floor_y, 0.0)
	var t := clampf((s - cfg.floor_width_m) / maxf(1.0, cfg.rise_run_m), 0.0, 1.0)
	# Steep off the floor, easing into the crest: what a scree-footed rock wall
	# does, and the shape that keeps the chasm reading as a chasm.
	var k := pow(t, cfg.rise_curve)
	var y := floor_y + (cfg.crest_y_m - floor_y) * k
	# The skyline. Scaled by k so the cleft floor stays a floor.
	y += (_fbm(along * cfg.ridge_scale, out_d * cfg.ridge_scale) - 0.5) \
		* 2.0 * cfg.ridge_relief_m * k
	# Gullies: finest band, strongest on the FACE rather than at either end,
	# which is where water would have cut them.
	y += (_fbm(along * cfg.gully_scale, out_d * cfg.gully_scale) - 0.5) \
		* 2.0 * cfg.gully_relief_m * k * (1.0 - k) * 4.0
	# Past the crest the range keeps climbing, slowly, so the horizon closes
	# behind a silhouette rather than at a flat lip.
	var past := maxf(0.0, s - cfg.floor_width_m - cfg.rise_run_m)
	y += minf(past * 0.10, 34.0)
	return Vector2(y, k)


## The cleft floor, under the whole map, seen through every discarded fragment.
func _floor_mesh(cfg: RavineConfig, map_size_m: Vector2) -> ArrayMesh:
	var nx := maxi(2, int(map_size_m.x / cfg.floor_cell_m))
	var nz := maxi(2, int(map_size_m.y / cfg.floor_cell_m))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for z in nz:
		for x in nx:
			var quad := [Vector2i(x, z), Vector2i(x + 1, z),
				Vector2i(x + 1, z + 1), Vector2i(x, z + 1)]
			# Wound so generate_normals() gives an UPWARD normal. Reversed,
			# the normals come out at (0, -1, 0) — the floor facing the rock
			# it is lying on — and cull_back then discards it, so the whole
			# surround renders as clear colour with no error anywhere.
			for corner in [0, 1, 2, 0, 2, 3]:
				var c: Vector2i = quad[corner]
				var px := float(c.x) / nx * map_size_m.x
				var pz := float(c.y) / nz * map_size_m.y
				var y := cfg.floor_y_m \
					+ (_fbm(px * 0.055, pz * 0.055) - 0.5) * 2.0 * cfg.floor_relief_m
				# NOT converted to linear. See _material: COLOR_0 is 8 bits per
				# channel, and these values converted land at 0.002, which
				# quantises to zero. The overall level lives in wall_albedo.
				st.set_color(cfg.deep_colour)
				st.set_uv(Vector2(px, pz) / cfg.rock_tile_m)
				st.add_vertex(Vector3(px, y, pz))
	st.generate_normals()
	# TANGENTS, and they are not optional. painted_prop.gdshader writes
	# NORMAL_MAP — inside a branch that this material never takes, but the
	# shader compiler decides NORMAL_MAP_USED at compile time, not at runtime,
	# so the vertex stage reads TANGENT on every mesh the shader touches. A
	# mesh without one renders BLACK, with no error anywhere, which is
	# indistinguishable from geometry that is not being drawn. Every other user
	# of this shader is a glTF import and got tangents for free.
	st.generate_tangents()
	return st.commit()


## The band outside the map frame: flat chasm floor, then the wall.
##
## Parametrised on the map RECT rather than on a circle. Every row is the rect
## inflated by `s` in both axes, which keeps the columns aligned across rows and
## puts the corners where the corners are — a circular ring around a 150 x 112
## map leaves a 20 m gap at the middle of the long sides or buries the short
## ones, and either way the chasm stops being a constant width.
func _ring_mesh(cfg: RavineConfig, map_size_m: Vector2,
		sun_dir: Vector2) -> ArrayMesh:
	var half := map_size_m * 0.5
	var centre := half
	# Columns: the unit-square boundary, sampled evenly by arc length on the
	# original rect so the spacing is uniform in metres at s = 0.
	var perimeter := 2.0 * (map_size_m.x + map_size_m.y)
	var cols := maxi(8, int(perimeter / cfg.wall_cell_m))
	var uw: Array[Vector2] = []
	var run: Array[float] = []          # arc length along the rect, for noise
	for i in cols:
		var d := perimeter * float(i) / cols
		uw.append(_rect_uw(d, map_size_m))
		run.append(d)

	# Rows: dense through the chasm and the wall face, coarse on the skirt.
	var rows: Array[float] = [0.0]
	var s := 0.0
	while s < cfg.floor_width_m:
		s = minf(s + cfg.floor_cell_m, cfg.floor_width_m)
		rows.append(s)
	var face_step := cfg.wall_cell_m * 1.5
	while s < cfg.floor_width_m + cfg.rise_run_m:
		s = minf(s + face_step, cfg.floor_width_m + cfg.rise_run_m)
		rows.append(s)
	# The skirt. Three rows are enough: nothing beyond the crest is near enough
	# to the camera for its silhouette to need resolving.
	var outer := cfg.extent_m - maxf(half.x, half.y)
	for f in [0.18, 0.45, 1.0]:
		rows.append(s + (outer - s) * f)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for j in rows.size() - 1:
		for i in cols:
			var i2 := (i + 1) % cols
			# Wound so the faces look INWARD and UP, at the map. The far side
			# of the ravine is what the camera sees; the outside of the range
			# is never visible and is culled. See _floor_mesh: the other
			# winding draws nothing at all.
			for corner in [[i, j], [i, j + 1], [i2, j + 1],
					[i, j], [i2, j + 1], [i2, j]]:
				_ring_vertex(st, cfg, centre, half, uw[corner[0]],
					run[corner[0]], rows[corner[1]], sun_dir)
	st.generate_normals()
	st.generate_tangents()          # see _floor_mesh: without these it is black
	return st.commit()


func _ring_vertex(st: SurfaceTool, cfg: RavineConfig, centre: Vector2,
		half: Vector2, uw: Vector2, along: float, s: float,
		sun_dir: Vector2) -> void:
	# THE CHASM IS NOT A CONSTANT WIDTH, and this is the line that stops the
	# surround reading as a picture frame. An exact offset rect puts a hard
	# straight edge and a square corner around the map; at the overhead camera
	# that is the first thing the eye finds, and no amount of rock colour
	# survives it. Wandering the offset by a low-frequency band makes the
	# chasm 6 to 20 metres wide instead of 13 everywhere.
	var wander := (_fbm(along * 0.020, 4.7) - 0.5) * 2.0 * cfg.edge_wander_m
	var se := maxf(0.0, s + wander * clampf(s / 26.0, 0.0, 1.0))
	var p := centre + Vector2(uw.x * (half.x + se), uw.y * (half.y + se))
	# AND IT ROUNDS OFF AS IT CLIMBS. The rect keeps the chasm the same width
	# on all four sides, which is what it is for; carried all the way out it
	# also keeps four right-angled corners on the skyline. Past the wall foot
	# the ring blends toward a circle, so the range closes as a bowl.
	var roundness := clampf(se / maxf(1.0, cfg.round_over_m), 0.0, 1.0)
	if roundness > 0.0:
		var dir := Vector2(uw.x * half.x, uw.y * half.y).normalized()
		var r0 := (half.x + half.y) * 0.5
		p = p.lerp(centre + dir * (r0 + se), roundness * roundness)
	var ys := _wall_y(cfg, se, along, se)
	# WHICH FLANK. The wall faces inward, so its horizontal normal is -uw. A
	# range lit evenly all the way round reads as a moulding; the reference's
	# has a lit side and a dark side, and this is the cheapest way to say so —
	# per vertex, before normals exist, from the column's own direction.
	var flank := clampf(-uw.normalized().dot(sun_dir) * 0.5 + 0.5, 0.0, 1.0)
	var k: float = ys.y
	var col := cfg.deep_colour.lerp(cfg.rock_colour, clampf(k * 2.2, 0.0, 1.0))
	col = col.lerp(cfg.crest_colour, clampf((k - 0.45) / 0.55, 0.0, 1.0))
	col = col.lerp(cfg.moonlit_colour, pow(flank, 2.0) * k * 0.72)
	st.set_color(col)
	st.set_uv(Vector2(along, s) / cfg.rock_tile_m)
	st.add_vertex(Vector3(p.x, ys.x, p.y))


## Distance `d` along the rect perimeter to a point on the unit square boundary,
## i.e. max(|u|, |w|) == 1. Inflating the rect is then (u * (hx + s),
## w * (hz + s)), which is an exact offset rect for any s.
static func _rect_uw(d: float, size: Vector2) -> Vector2:
	var x := size.x
	var z := size.y
	# The four edges in order: north, east, south, west.
	if d < x:
		return Vector2(d / x * 2.0 - 1.0, -1.0)
	d -= x
	if d < z:
		return Vector2(1.0, d / z * 2.0 - 1.0)
	d -= z
	if d < x:
		return Vector2(1.0 - d / x * 2.0, 1.0)
	d -= x
	return Vector2(-1.0, 1.0 - clampf(d / z, 0.0, 1.0) * 2.0)


# --- noise ------------------------------------------------------------------
## Deterministic value noise. Duplicated from the shaders rather than shared:
## it is ten lines, this runs once at load, and a shared helper is one more
## file to get wrong for no saving.
static func _hash(x: int, y: int) -> float:
	var h := x * 374761393 + y * 668265263
	h = (h ^ (h >> 13)) * 1274126177
	return float((h ^ (h >> 16)) & 0xFFFFFF) / float(0xFFFFFF)


static func _vnoise(x: float, y: float) -> float:
	var ix := int(floor(x))
	var iy := int(floor(y))
	var fx: float = x - floor(x)
	var fy: float = y - floor(y)
	fx = fx * fx * (3.0 - 2.0 * fx)
	fy = fy * fy * (3.0 - 2.0 * fy)
	return lerpf(lerpf(_hash(ix, iy), _hash(ix + 1, iy), fx),
		lerpf(_hash(ix, iy + 1), _hash(ix + 1, iy + 1), fx), fy)


static func _fbm(x: float, y: float) -> float:
	return _vnoise(x, y) * 0.55 + _vnoise(x * 2.3 + 11.0, y * 2.3 + 3.0) * 0.28 \
		+ _vnoise(x * 4.7 + 5.0, y * 4.7 + 19.0) * 0.17
