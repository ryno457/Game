class_name ScanFx
extends RefCounted
## Drive shaders/scan_dissolve.gdshader on one object.
##
##     ScanFx.scan(mesh, 1.8)                  # sweep a band over it
##     ScanFx.dissolve(mesh, 2.4)              # take it apart, then free it
##     ScanFx.assemble(mesh, 1.6)              # the same, backwards, to build
##
## THE MATERIAL IS SWAPPED, NOT AUTHORED. Every prop, machine and module in this
## project is already wearing painted_prop.gdshader with a pile of parameters
## the model needs to look like itself — its albedo tint, the shared tone ramp,
## its baked detail normal and AO. A dissolve that threw those away would take
## the object apart and turn it a different colour on the way, which reads as a
## bug rather than an effect.
##
## So the swap COPIES EVERY PARAMETER THE TWO SHADERS SHARE, by asking the
## shaders themselves which ones those are rather than listing them here. A list
## would be wrong the first time either shader gains a uniform, and it would be
## wrong silently.
##
## WHY NOT JUST PUT THE DISSOLVE IN painted_prop. Because `discard` costs
## early-Z for every draw that shares the shader, and painted_prop is also worn
## by a 600-instance scenery MultiMesh that will never dissolve. See the note at
## the top of scan_dissolve.gdshader.

const SHADER := "res://shaders/scan_dissolve.gdshader"

## One noise texture for the whole game. It is 128 px of FastNoiseLite and it
## does not vary per object — the variation that matters comes from each mesh's
## own geometry and height, not from having its own noise.
static var _noise: NoiseTexture2D = null


static func noise() -> NoiseTexture2D:
	if _noise == null:
		var n := FastNoiseLite.new()
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		# Coarse. The shader scales it again per object; what matters here is
		# that the flecks are CHUNKS rather than per-pixel static, which reads
		# as matter coming apart instead of as television snow.
		n.frequency = 0.045
		_noise = NoiseTexture2D.new()
		_noise.width = 128
		_noise.height = 128
		_noise.seamless = true
		_noise.noise = n
	return _noise


## Put the dissolve shader on `mi`, carrying over everything it was wearing.
## Returns the new material, or null if the node cannot take one.
static func equip(mi: GeometryInstance3D) -> ShaderMaterial:
	if mi == null:
		return null
	var src: Material = mi.material_override
	if src == null and mi is MeshInstance3D:
		var m := mi as MeshInstance3D
		if m.mesh != null and m.mesh.get_surface_count() > 0:
			src = m.get_active_material(0)
	var mat := ShaderMaterial.new()
	mat.shader = load(SHADER)
	if src is ShaderMaterial:
		var from := src as ShaderMaterial
		# Ask the shaders which uniforms they have in common. get_shader_uniform_list
		# reports the parameter names; anything the destination does not declare
		# is skipped, and anything it declares that the source lacks keeps the
		# shader's own default.
		var want := {}
		for u in mat.shader.get_shader_uniform_list():
			want[String(u["name"])] = true
		if from.shader != null:
			for u in from.shader.get_shader_uniform_list():
				var name := String(u["name"])
				if want.has(name):
					var v: Variant = from.get_shader_parameter(name)
					if v != null:
						mat.set_shader_parameter(name, v)
	mat.set_shader_parameter("noise_tex", noise())
	mat.set_shader_parameter("object_h_m", _height_m(mi))
	mi.material_override = mat
	return mat


## How tall the mesh is in its own space, so the shader can normalise height
## without a bounding-box lookup per fragment. Falls back to 2 m — a wrong
## height makes the sweep start early or late, never makes it fail.
static func _height_m(mi: GeometryInstance3D) -> float:
	if mi is MeshInstance3D:
		var m := mi as MeshInstance3D
		if m.mesh != null:
			var h: float = m.mesh.get_aabb().size.y
			if h > 0.01:
				return h
	return 2.0


## Sweep a reading band over the object and leave it intact.
static func scan(mi: GeometryInstance3D, secs := 1.8,
		colour := Color(0.55, 0.95, 1.0)) -> Tween:
	var mat := equip(mi)
	if mat == null:
		return null
	mat.set_shader_parameter("scan_colour", colour)
	mat.set_shader_parameter("dissolve", 0.0)
	var tw := mi.create_tween()
	tw.tween_method(
		func(v: float): mat.set_shader_parameter("scan_pos", v), 0.0, 1.0, secs)
	# Park the band off the object afterwards. -1 is the off switch; leaving it
	# at 1.0 would keep a lit line welded across the base of everything ever
	# scanned.
	tw.tween_callback(func(): mat.set_shader_parameter("scan_pos", -1.0))
	return tw


## Take the object apart. Frees it when done unless `free_after` is false.
static func dissolve(mi: GeometryInstance3D, secs := 2.4,
		colour := Color(0.55, 0.95, 1.0), free_after := true) -> Tween:
	return _run(mi, secs, colour, 0.0, 1.0, free_after)


## The same, backwards: the object assembles out of nothing. This is what a
## module being built looks like, and it is the same shader — there is no
## separate build effect because there does not need to be one.
static func assemble(mi: GeometryInstance3D, secs := 1.6,
		colour := Color(1.0, 0.78, 0.35)) -> Tween:
	return _run(mi, secs, colour, 1.0, 0.0, false)


static func _run(mi: GeometryInstance3D, secs: float, colour: Color,
		from: float, to: float, free_after: bool) -> Tween:
	var mat := equip(mi)
	if mat == null:
		return null
	mat.set_shader_parameter("edge_colour", colour)
	mat.set_shader_parameter("scan_pos", -1.0)
	mat.set_shader_parameter("dissolve", from)
	var tw := mi.create_tween()
	tw.tween_method(
		func(v: float): mat.set_shader_parameter("dissolve", v), from, to, secs)
	if free_after:
		tw.tween_callback(mi.queue_free)
	else:
		# Back to the plain material once it is whole again, so the object stops
		# paying for a discard it no longer does. This is the entire reason the
		# dissolve is a separate shader; not undoing the swap would leak that
		# cost onto every module the player ever builds.
		tw.tween_callback(func(): mi.material_override = null)
	return tw
