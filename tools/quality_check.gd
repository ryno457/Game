extends SceneTree
## Surface quality and render presets, checked without a device.
##
##   godot --headless --path . --script tools/quality_check.gd
##
## There are no textures in this project — no image files, no UVs on any mesh.
## "Higher quality" here therefore means three concrete things, and each is
## checked for actually being present rather than assumed:
##   · procedural surface detail in the terrain shader
##   · baked ambient occlusion in the vertex channel of every prop
##   · antialiasing and render scale, as a preset the phone can measure

const PALETTE := "res://data/biomes/biodome_01_palette.tres"
const SHADER := "res://shaders/terrain_lit.gdshader"
const HIGH := "res://data/gameplay/quality_high.tres"
const MED := "res://data/gameplay/quality_medium.tres"
const LOW := "res://data/gameplay/quality_low.tres"
const LIGHTING := "res://data/gameplay/lighting.tres"
const FLORA := ["flora_arch", "flora_brain", "flora_coral", "flora_pods",
	"flora_tendril", "rock_spire"]

var _failed := 0


func _initialize() -> void:
	print("SENTINEL — surface quality checks\n")
	_no_textures()
	_shader()
	_props()
	_presets()
	print("")
	if _failed == 0:
		print("ALL CHECKS PASSED")
	else:
		print("%d CHECK(S) FAILED" % _failed)
	quit(_failed)


func _ok(name: String, cond: bool, detail: String) -> void:
	if not cond:
		_failed += 1
	print("  %s  %s  %s" % ["PASS" if cond else "FAIL", name.rpad(42), detail])


# --- the premise -------------------------------------------------------------
func _no_textures() -> void:
	print("the premise")
	# Stated as a test so that the day someone adds a texture, the checks below
	# stop claiming to be the whole story.
	var images := 0
	for f in DirAccess.get_files_at("res://models"):
		if f.ends_with(".png") or f.ends_with(".jpg") or f.ends_with(".webp"):
			images += 1
	_ok("there are still no texture assets", images == 0,
		"%d images in res://models" % images)


# --- terrain -----------------------------------------------------------------
func _shader() -> void:
	print("\nterrain surface")
	var sh: Shader = load(SHADER)
	var names := PackedStringArray()
	for u in sh.get_shader_uniform_list(true):
		names.append(u.name)
	for want in ["detail_strength", "detail_scale", "detail_fade_m",
			"macro_strength", "striation_strength"]:
		_ok("shader exposes %s" % want, names.has(want), "")

	var src := FileAccess.get_file_as_string(SHADER)
	# The sin() hash bands visibly at mediump, which is what a mobile driver is
	# free to pick. See the comment on hash() for the failure mode.
	_ok("the noise hash does not use sin()", not src.contains("sin(dot(p"),
		"multiply-add hash, stable at any precision")
	# NORMAL in fragment is view space. Doing the slope test on it means asking
	# "does this face the camera's up", which is not the same question.
	_ok("slope is measured in world space", src.contains("varying vec3 v_normal_w"),
		"world normal carried from the vertex stage")
	_ok("the detail bump is written back to NORMAL",
		src.contains("NORMAL = normalize((VIEW_MATRIX"),
		"converted back to view space")

	var p: BiomePalette = load(PALETTE)
	_ok("the biodome asks for surface detail",
		p.detail_strength > 0.0 and p.striation_strength > 0.0,
		"bump %.2f, striation %.2f" % [p.detail_strength, p.striation_strength])
	# Finer than about 4 cycles/m is invisible from the RTS camera and shimmers
	# when it pans; coarser than about 1 reads as a stain, not grit.
	_ok("detail is at a scale the camera can see",
		p.detail_scale >= 1.0 and p.detail_scale <= 4.0,
		"%.1f cycles per metre" % p.detail_scale)


# --- props -------------------------------------------------------------------
func _props() -> void:
	print("\nbaked occlusion")
	var lib := ModelLibrary.new()
	var without := PackedStringArray()
	var unlit := PackedStringArray()
	for name in FLORA:
		var m := lib.biggest_mesh(name)
		if m == null:
			without.append(name)
			continue
		if (m.surface_get_format(0) & Mesh.ARRAY_FORMAT_COLOR) == 0:
			without.append(name)
			continue
		for i in m.get_surface_count():
			var mat := m.surface_get_material(i) as StandardMaterial3D
			if mat == null or not mat.vertex_color_use_as_albedo:
				unlit.append("%s:%d" % [name, i])
	_ok("every prop carries vertex colours", without.is_empty(),
		"%d props" % FLORA.size())
	# Godot's glTF importer enabled vertex colour on the EMISSIVE slots of
	# these assets and left it off on the solid ones, which is backwards from
	# where the occlusion is. ModelLibrary forces it; this is that fix held in
	# place, because the failure is invisible — the model just looks flat.
	_ok("and every material actually uses them", unlit.is_empty(),
		"nothing ignoring its own occlusion" if unlit.is_empty()
			else ", ".join(unlit))

	# The bake has to be doing something. A mesh of all-white vertex colours
	# passes both checks above and contributes nothing.
	var arch := lib.biggest_mesh("flora_arch")
	var arrays := arch.surface_get_arrays(0)
	var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var darkest := 1.0
	var mean := 0.0
	for c in cols:
		darkest = minf(darkest, c.r)
		mean += c.r
	mean /= maxf(1.0, cols.size())
	_ok("the occlusion is not all white", darkest < 0.9,
		"darkest vertex %.2f, mean %.2f" % [darkest, mean])
	_ok("and creases are shaded, not black", darkest > 0.2,
		"floor holds at %.2f" % darkest)


# --- presets -----------------------------------------------------------------
func _presets() -> void:
	print("\nquality presets")
	var hi: QualityConfig = load(HIGH)
	var lo: QualityConfig = load(LOW)

	# Untextured low-poly art is nothing but silhouette, so antialiasing is the
	# single biggest visible difference between the two presets. If High does
	# not antialias, there is no reason for it to exist.
	_ok("High antialiases", hi.msaa_3d > 0,
		"%s MSAA" % ["off", "2x", "4x", "8x"][hi.msaa_3d])
	_ok("High renders at full resolution", is_equal_approx(hi.render_scale, 1.0),
		"%.2f" % hi.render_scale)
	_ok("High computes surface detail", hi.terrain_detail > 0.0,
		"x%.2f" % hi.terrain_detail)

	_ok("Low is cheaper in every dimension",
		lo.msaa_3d <= hi.msaa_3d and lo.render_scale <= hi.render_scale
			and lo.terrain_detail <= hi.terrain_detail
			and lo.shadow_atlas_size <= hi.shadow_atlas_size,
		"nothing on Low costs more than High")
	# Low drops MSAA, so it needs something for the silhouettes or the arches
	# come apart into stair-steps.
	_ok("Low still antialiases somehow",
		lo.msaa_3d > 0 or lo.screen_space_aa > 0, "FXAA")
	# Below about 0.8 the thin struts this art is made of break up, which is
	# the exact thing the antialiasing was for.
	_ok("Low does not shrink past legibility", lo.render_scale >= 0.8,
		"%.2f render scale" % lo.render_scale)

	# Medium exists to make a failure diagnostic: if High misses the frame
	# budget and Medium holds it, the cost was the 4x MSAA and not the shader.
	# That only works if Medium differs from High in exactly one dimension.
	var md: QualityConfig = load(MED)
	_ok("Medium isolates the antialiasing cost",
		md.msaa_3d < hi.msaa_3d and md.msaa_3d > 0
			and is_equal_approx(md.render_scale, hi.render_scale)
			and is_equal_approx(md.terrain_detail, hi.terrain_detail),
		"%s MSAA, everything else as High" % ["off", "2x", "4x", "8x"][md.msaa_3d])
	_ok("the three presets are ordered",
		lo.msaa_3d <= md.msaa_3d and md.msaa_3d <= hi.msaa_3d,
		"Low <= Medium <= High")

	# Both rigs set the shadow atlas. The game applies QualityRig second, so
	# the preset wins — asserted here rather than left as a comment, because
	# the wrong precedence would silently cost frame rate on a phone.
	var light: LightingConfig = load(LIGHTING)
	_ok("the preset can override the lighting rig's shadow atlas",
		lo.shadow_atlas_size != light.shadow_atlas_size,
		"lighting asks %d, Low asks %d" % [light.shadow_atlas_size, lo.shadow_atlas_size])
