class_name ModelLibrary
extends RefCounted

const PAINTED_SHADER := "res://shaders/painted_prop.gdshader"
## The skin the ground and the vines wear, from tools/make_scale_detail.py.
## Everything that GREW shares it; the machines do not, and that is the line
## the whole look rests on.
const SCALE_N := "res://textures/scale_detail_n.png"
const SCALE_AO := "res://textures/scale_detail_ao.png"

## Set before the first load_model() call. Null leaves models on their
## imported StandardMaterial3D, which is the grey-box look.
var painted_ramp: Texture2D
var painted_ink := 0.35
## How hard the machines' baked normal map bites. 0 leaves them smooth.
var painted_machine_detail := 0.0
## And how hard the shared scale map bites on everything that grew.
var painted_scale_detail := 0.0
## ONE COLOUR FOR EVERY MACHINE, overriding what each model was authored with.
## Alpha 0 means leave them alone, which is what a checkout without the palette
## field gets. See MACHINES for what counts as one and apply_painted for why the
## emissive slots are exempt.
var painted_machine_albedo := Color(0.0, 0.0, 0.0, 0.0)
## Loads the Blender-authored glTF assets and hands out ready-to-place nodes.
##
## Two things it fixes centrally rather than per-caller:
##
## 1. GROUNDING. The authoring convention is "origin at ground contact", but
##    three assets ship 7-17 cm low. Rather than patch each build script and
##    hope the next one complies, every instance is offset by its own AABB so
##    it sits on the terrain regardless of how it was authored.
##
## 2. THE MULTIMESH LINE. A skinned mesh CANNOT be rendered through MultiMesh —
##    Godot has nowhere to put per-instance bone matrices. The aliens are
##    skinned, so they are individual nodes; the convoy is small enough that
##    individual nodes also buy animated sub-parts for free. Only large static
##    crowds (debris) stay instanced. That line is the whole reason unit counts
##    behave the way Spike A measured.
##
## 3. VERTEX COLOURS. The assets carry baked ambient occlusion in COLOR_0 —
##    this project has no textures, so the vertex channel is where surface
##    detail lives. Godot's glTF importer decides per material whether to
##    honour it, and on these assets it decided WRONG: it enabled vertex
##    colour on the emissive slots (where the bake is deliberately white) and
##    left it off on the solid ones (where all the occlusion is). Forced on
##    here for every material, once, rather than fought per asset.

const DIR := "res://models/"

## WHICH MODELS ARE MACHINES. Listed rather than inferred from a prefix, the way
## sways() infers flora, because the machines do not share one: bulwark, guard,
## turret and radar are the buildable ones, drone and module_forms are the
## player's own. Anything not named here — the aliens, the flora, rock_spire —
## keeps the colour it was authored with, which is the point: the aliens must
## NOT go grey with them.
const MACHINES := ["bulwark", "drone", "guard", "module_forms", "radar",
	"turret"]


static func is_machine(model_name: String) -> bool:
	return MACHINES.has(model_name)

var _scenes: Dictionary = {}     # name -> PackedScene
var _ground: Dictionary = {}     # name -> float offset


func load_model(model_name: String) -> PackedScene:
	if _scenes.has(model_name):
		return _scenes[model_name]
	var path := DIR + model_name + ".glb"
	if not ResourceLoader.exists(path):
		push_warning("model missing: %s" % path)
		return null
	var packed: PackedScene = load(path)
	_apply_vertex_colours(packed)
	# One lighting model for everything on screen. See apply_painted: the
	# terrain and everything else were lit by different models, and the moon rig
	# was tuned for the terrain, so a light grey machine rendered darker than
	# the ground it stood on.
	if painted_ramp != null:
		apply_painted(packed, painted_ramp, painted_ink, model_name,
			painted_machine_detail, painted_scale_detail,
			painted_machine_albedo)
	_scenes[model_name] = packed
	return packed


## Turn on vertex-colour albedo for every material in a model.
##
## Mutates the imported mesh resources, which are shared and cached, so this
## runs once per model on first load and every instance after it — node-spawned
## or MultiMesh — gets the baked occlusion. See the class comment for why the
## importer cannot be trusted to do it.
##
## Returns how many materials it had to change, which is the number worth
## logging if this ever looks like it did nothing.
static func _apply_vertex_colours(packed: PackedScene) -> int:
	var probe: Node = packed.instantiate()
	var changed := 0
	for node in probe.find_children("*", "MeshInstance3D", true, false):
		var m: Mesh = (node as MeshInstance3D).mesh
		if m == null or (m.surface_get_format(0) & Mesh.ARRAY_FORMAT_COLOR) == 0:
			continue
		for i in m.get_surface_count():
			var mat := m.surface_get_material(i) as StandardMaterial3D
			if mat != null and not mat.vertex_color_use_as_albedo:
				mat.vertex_color_use_as_albedo = true
				changed += 1
	probe.free()
	return changed


## Swap every StandardMaterial3D on a model for the painted shader.
##
## Props, plants and machines used to be lit by Godot's default Lambert while
## the terrain ran its own light() with a tone ramp reaching a gain of 2.98.
## The moon rig was then tuned so the TERRAIN hit the reference's value, which
## left everything else underlit by about that gain — measured on a frame, a
## light grey module rendered DARKER than the teal ground it stood on. One
## lighting model for everything is the fix; two was the bug.
##
## Mutates the shared cached mesh resources, like _apply_vertex_colours above,
## so every instance after the first gets it — node-spawned or MultiMesh.
## How far the top of a plant sways, in metres, and how fast. Zero on anything
## that is not flora, which is how the shader's branch stays cheap for machines
## and rocks. Set from EffectsConfig before anything spawns.
static var painted_sway_m := 0.0
static var painted_sway_hz := 0.32
static var painted_sway_ref_h := 3.0


## Does this model bend in the wind?
##
## BY NAME, which is crude and correct here: every growing thing in this
## project is called flora_something, and the alternative — a flag on each
## model's import — is a file to forget to tick. A rock spire and an alien ruin
## are deliberately excluded: they are stone, and stone that sways is worse
## than stone that does not move.
static func sways(model_name: String) -> bool:
	return model_name.begins_with("flora")


static func apply_painted(packed: PackedScene, ramp: Texture2D,
		ink := 0.35, model_name := "", machine_detail := 0.0,
		scale_detail := 0.0,
		machine_albedo := Color(0.0, 0.0, 0.0, 0.0)) -> int:
	var shader: Shader = load(PAINTED_SHADER)
	if shader == null:
		return 0
	var probe: Node = packed.instantiate()
	var changed := 0
	for node in probe.find_children("*", "MeshInstance3D", true, false):
		var m: Mesh = (node as MeshInstance3D).mesh
		if m == null:
			continue
		var has_col: bool = (m.surface_get_format(0) & Mesh.ARRAY_FORMAT_COLOR) != 0
		# DOES THIS MESH HAVE UVs AT ALL. Not a theoretical question: commit
		# 70e48ae re-exported drone, guard and module_forms from the procedural
		# builders to add the COLOR_0 sky bake and dropped TEXCOORD_0 and
		# TANGENT doing it, which commit 52bfe40 had added for the panel-seam
		# bake. The detail branch below kept running, so every fragment sampled
		# machine_*_ao.png at UV(0, 0) — the black corner of the atlas — and
		# multiplied the albedo by 0.30 on the module and 0.47 on the guard.
		# That is why the machines were dark, and it would have eaten any grey
		# put in front of it.
		var has_uv: bool = (m.surface_get_format(0) & Mesh.ARRAY_FORMAT_TEX_UV) != 0
		for i in m.get_surface_count():
			var std := m.surface_get_material(i) as StandardMaterial3D
			if std == null:
				continue
			var sm := ShaderMaterial.new()
			sm.shader = shader
			# ONE GREY FOR THE MACHINES, and only for the parts that are not
			# lights. Overriding every slot would take the cyan out of the
			# drone's pods and the turret's sight, which is the only colour
			# those models have and the only thing that says a machine is
			# powered. Emissive slots keep what they were authored with.
			#
			# This does not touch the baked sky light: that arrives in COLOR_0
			# and painted_prop multiplies albedo BY it, so the grey is the
			# pigment and the vertex colour is still the shading. Recolouring
			# in the Blender builders instead would have meant re-exporting six
			# models to change one look decision.
			var lit: bool = std.emission_enabled \
				and std.emission_energy_multiplier > 0.0
			if machine_albedo.a > 0.0 and is_machine(model_name) and not lit:
				sm.set_shader_parameter("albedo", machine_albedo)
			else:
				sm.set_shader_parameter("albedo", std.albedo_color)
			sm.set_shader_parameter("roughness_v", std.roughness)
			sm.set_shader_parameter("emission_tint", std.emission)
			# emission_energy_multiplier, not emission_energy: the latter does
			# not exist on StandardMaterial3D in Godot 4 and access throws.
			sm.set_shader_parameter("emission_energy",
				std.emission_energy_multiplier if std.emission_enabled else 0.0)
			sm.set_shader_parameter("use_vertex_colour", has_col)
			sm.set_shader_parameter("tone_ramp", ramp)
			sm.set_shader_parameter("rim_ink", ink)
			if sways(model_name):
				sm.set_shader_parameter("sway_m", painted_sway_m)
				sm.set_shader_parameter("sway_hz", painted_sway_hz)
				sm.set_shader_parameter("sway_ref_h", painted_sway_ref_h)
			# The machines' baked detail, if this model has any. Named by
			# model, written by tools/blender/bake_machines.py.
			var n_path := "res://textures/machine_%s_n.png" % model_name
			var ao_path := "res://textures/machine_%s_ao.png" % model_name
			if not has_uv:
				# No UVs, so no detail maps — sampling them would multiply the
				# albedo by whatever happens to be at the atlas corner. Loud,
				# because a model silently losing its unwrap on re-export is
				# exactly how this shipped dark for a week.
				if ResourceLoader.exists(n_path):
					push_warning(("%s has a baked detail map but no UVs — "
						+ "re-export it with TEXCOORD_0 or the map is dead "
						+ "weight") % model_name)
				sm.set_shader_parameter("detail_strength", 0.0)
			elif ResourceLoader.exists(n_path) and ResourceLoader.exists(ao_path):
				sm.set_shader_parameter("detail_n", load(n_path))
				sm.set_shader_parameter("detail_ao", load(ao_path))
				sm.set_shader_parameter("detail_strength", machine_detail)
			elif scale_detail > 0.0 and ResourceLoader.exists(SCALE_N):
				# EVERYTHING THAT GREW WEARS THE SAME SKIN. A prop with no baked
				# map of its own is a plant or a ruin, and those get the shared
				# scale texture through the UVs build_flora unwraps. The ground
				# and the vines are already wearing it; the structures standing
				# on them were the one thing still smooth.
				sm.set_shader_parameter("detail_n", load(SCALE_N))
				sm.set_shader_parameter("detail_ao", load(SCALE_AO))
				sm.set_shader_parameter("detail_strength", scale_detail)
				sm.set_shader_parameter("detail_ao_strength", 0.5)
			m.surface_set_material(i, sm)
			changed += 1
	probe.free()
	return changed


## Instance a model, grounded, optionally keeping only one named subtree.
## `keep` matters for module_forms.glb, which holds all three growth forms
## overlapping at the origin — importing it whole gives three nested machines.
func spawn(model_name: String, keep := "") -> Node3D:
	var packed := load_model(model_name)
	if packed == null:
		return null
	var root: Node3D = packed.instantiate()
	if keep != "":
		var wanted := root.find_child(keep, true, false)
		if wanted == null:
			push_warning("subtree '%s' not found in %s" % [keep, model_name])
		else:
			var holder := Node3D.new()
			holder.name = keep
			wanted.get_parent().remove_child(wanted)
			# Clear the owner first: it still points at the discarded glTF root,
			# and re-parenting an owned node without this warns about an
			# inconsistent owner on every swap.
			_clear_owner(wanted)
			holder.add_child(wanted)
			(wanted as Node3D).position = Vector3.ZERO
			root.free()
			root = holder
	_apply_ground_offset(root, model_name + "/" + keep)
	return root


static func _clear_owner(n: Node) -> void:
	n.owner = null
	for c in n.get_children():
		_clear_owner(c)


## Shift the instance so its lowest vertex sits at y = 0.
func _apply_ground_offset(root: Node3D, key: String) -> void:
	if not _ground.has(key):
		var lowest := 1e9
		for mi in root.find_children("*", "MeshInstance3D", true, false):
			var aabb: AABB = (mi as MeshInstance3D).mesh.get_aabb()
			var world_y: float = (mi as MeshInstance3D).position.y + aabb.position.y
			lowest = minf(lowest, world_y)
		_ground[key] = 0.0 if lowest > 1e8 else -lowest
	var off: float = _ground[key]
	if not is_zero_approx(off):
		for c in root.get_children():
			if c is Node3D:
				(c as Node3D).position.y += off


## The single biggest mesh in a model, for the cases that DO instance.
func biggest_mesh(model_name: String) -> Mesh:
	var packed := load_model(model_name)
	if packed == null:
		return null
	var inst: Node3D = packed.instantiate()
	var best: Mesh = null
	var best_n := -1
	for mi in inst.find_children("*", "MeshInstance3D", true, false):
		var m: Mesh = (mi as MeshInstance3D).mesh
		if m == null:
			continue
		var n := 0
		for s in m.get_surface_count():
			n += m.surface_get_array_len(s)
		if n > best_n:
			best_n = n
			best = m
	inst.free()
	return best


## Name of the animation to play, preferring `want`, else the first available.
static func pick_animation(player: AnimationPlayer, want: String) -> String:
	if player == null:
		return ""
	var list := player.get_animation_list()
	for a in list:
		if a == want or a.ends_with("/" + want):
			return a
	return list[0] if list.size() > 0 else ""
