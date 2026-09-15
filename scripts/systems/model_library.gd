class_name ModelLibrary
extends RefCounted
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
