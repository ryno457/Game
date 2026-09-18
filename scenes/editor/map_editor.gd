extends Node3D
## The map editor, and it runs on the phone.
##
##   Open the project in Godot, set the main scene to this, or press the EDITOR
##   button in the prototype's build bar.
##
## WHY IT IS INSIDE THE GAME rather than a desktop tool. The map has to be
## judged at the camera it is played at, on the screen it is played on, under
## the lighting it ships with. A plan view on a laptop is a different question
## from "can I read this plateau on a phone at arm's length", and that second
## question is the one that decides whether a map is any good.
##
## EVERYTHING IS A LIST OF EDITS. Sculpting appends ops in TerrainBuilder's own
## vocabulary, so undo is popping one off and saving is serialising the list —
## the same shape TerrainMap already uses. See MapEdit.
##
## WHAT IT DOES NOT DO. It does not write .tres files: a phone has no business
## writing into the repository, and a half-written resource is a broken game.
## It writes JSON, which goes back to the desk and through tools/apply_map_edit
## — which validates every entry before it writes anything.

const MAP := "res://data/terrain/biodome_map_01.tres"
const PALETTE := "res://data/biomes/biodome_01_palette.tres"
const DRESSING := "res://data/biomes/biodome_01_dressing.tres"
const HIVE := "res://data/gameplay/hive.tres"
const TERRAIN_SHADER := "res://shaders/terrain_lit.gdshader"
const LIGHT_CFG := "res://data/gameplay/lighting.tres"
const RAVINE := "res://data/biomes/biodome_01_ravine.tres"
const PROTO_CFG := "res://data/gameplay/proto.tres"
const QUALITY_HIGH := "res://data/gameplay/quality_high.tres"
## Where a save lands. user:// because it is the only path that is writable on
## every platform this runs on — res:// is read-only in an exported game and
## the Android editor's project folder is not somewhere to be writing at all.
const SAVE_PATH := "user://map_edit.json"

enum Tool {RAISE, LOWER, FLATTEN, PLATEAU, BLOCK, WALL, PLANT, ROAMER, NEST,
	PATCH, ERASE}

@onready var terrain: TerrainView = $Terrain
@onready var rig: Node3D = $CameraRig
@onready var camera: Camera3D = $CameraRig/Camera3D
@onready var sun: DirectionalLight3D = $Sun
@onready var world_env: WorldEnvironment = $WorldEnvironment
@onready var tool_bar: GridContainer = $HUD/Side/Scroll/Tools
@onready var readout: Label = $HUD/Top/Text
@onready var status: Label = $HUD/Bottom/Col/Text
@onready var brush_slider: HSlider = $HUD/Bottom/Col/Row/Brush
@onready var brush_label: Label = $HUD/Bottom/Col/Row/BrushLabel
@onready var level_slider: HSlider = $HUD/Bottom/Col/Row/Level
@onready var level_label: Label = $HUD/Bottom/Col/Row/LevelLabel
@onready var count_slider: HSlider = $HUD/Bottom/Col/Row/Count
@onready var count_label: Label = $HUD/Bottom/Col/Row/CountLabel

var field: Heightfield
var palette: BiomePalette
var tune: ProtoConfig
var hive_cfg: HiveConfig
var edit := MapEdit.new()
var tool_now := Tool.RAISE
var brush_m := 6.0
var level := 0.5
var spawn_count := 3

var _mm_marks: MultiMeshInstance3D
var _lib := ModelLibrary.new()
var _plant_nodes: Array[Node3D] = []
var _tool_buttons: Dictionary = {}
var _map_w := 0.0
var _map_h := 0.0
var _dirty_since_save := false
var _rebake_due := false
## Corners of the wall being drawn, in cell space. Empty means no wall is in
## progress, which is also what CLOSE and CANCEL leave behind.
var _wall_pts: Array = []


func _ready() -> void:
	tune = load(PROTO_CFG)
	hive_cfg = load(HIVE)
	LightingRig.apply(load(LIGHT_CFG), sun, world_env)
	var map: TerrainMap = load(MAP)
	edit.map_path = MAP
	field = TerrainBuilder.build(map)
	var cfg := field.cfg
	_map_w = cfg.cells_x * cfg.cell_size_m
	_map_h = cfg.cells_z * cfg.cell_size_m

	# A fog of war with nothing hidden. The editor has to see the whole map —
	# but the terrain shader samples a fog map whatever happens, so it needs a
	# real one that says "all visible" rather than no fog at all.
	var fog := FogOfWar.new(Vector2i(cfg.cells_x, cfg.cells_z), cfg.cell_size_m)
	fog.begin_frame()
	fog.reveal(Vector2(_map_w * 0.5, _map_h * 0.5), maxf(_map_w, _map_h))
	terrain.setup(field, fog, load(TERRAIN_SHADER))
	palette = load(PALETTE)
	_lib.painted_ramp = TerrainView.ramp_texture(palette)
	_lib.painted_ink = palette.prop_rim_ink
	_lib.painted_machine_detail = palette.machine_detail
	_lib.painted_scale_detail = palette.scale_detail
	_rebake()
	add_child(RavineWall.build(load(RAVINE), Vector2(_map_w, _map_h),
		TerrainView.ramp_texture(palette),
		LightingRig.sun_ground_dir(load(LIGHT_CFG))))

	_mm_marks = MultiMeshInstance3D.new()
	_mm_marks.multimesh = MultiMesh.new()
	_mm_marks.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_mm_marks.multimesh.use_colors = true
	_mm_marks.multimesh.mesh = _marker_mesh()
	_mm_marks.multimesh.instance_count = 2048
	_mm_marks.multimesh.visible_instance_count = 0
	_mm_marks.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mm_marks)

	# THE QUALITY PRESET IS NOT OPTIONAL, and not for the reason the name
	# suggests. TerrainView builds its chunk meshes inside
	# set_detail_scale_factor(), which only QualityRig calls — so an editor
	# that skipped "quality settings" as cosmetic got a terrain with zero
	# geometry in it and rendered a perfectly laid out HUD over a black
	# screen. It also means the editor judges the map at the same fidelity the
	# game will draw it, which is the entire point of editing in here.
	QualityRig.apply(load(QUALITY_HIGH), get_viewport(), terrain, palette,
		null)

	rig.position = Vector3(_map_w * 0.5, 0.0, _map_h * 0.5)
	_frame_camera()
	_build_tools()
	_wire_sliders()
	# Whatever was saved last time. Losing an afternoon of placement to a phone
	# call is not a thing an editor should be able to do.
	if FileAccess.file_exists(SAVE_PATH):
		var err := edit.load_from(SAVE_PATH)
		if err == "":
			_replay()
			_say("Picked up where you left off.")
		else:
			_say("Could not read the last save: " + err)
	else:
		_say("Pick a tool, then tap the ground.")
	_refresh()


# --- the tools ---------------------------------------------------------------
const TOOL_LABEL := {
	Tool.RAISE: "RAISE\nground",
	Tool.LOWER: "LOWER\nground",
	Tool.FLATTEN: "FLATTEN\nto level",
	Tool.PLATEAU: "PLATEAU\nstamp",
	Tool.BLOCK: "BLOCK\ncarve a hole",
	Tool.WALL: "WALL\nfree form",
	Tool.PLANT: "PLANT\nvegetation",
	Tool.ROAMER: "ROAMER\nbig alien",
	Tool.NEST: "NEST\nplant hive",
	Tool.PATCH: "PATCH\nburrow",
	Tool.ERASE: "ERASE\nnearest",
}


func _build_tools() -> void:
	for t in TOOL_LABEL:
		var b := Button.new()
		b.text = TOOL_LABEL[t]
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(168.0, 84.0)
		b.add_theme_font_size_override("font_size", 18)
		b.pressed.connect(_pick_tool.bind(t))
		tool_bar.add_child(b)
		_tool_buttons[t] = b
	_pick_tool(Tool.RAISE)

	for spec in [["CLOSE\nwall", _close_wall], ["CANCEL\nwall", _cancel_wall],
			["UNDO", _undo], ["SAVE", _save], ["COPY JSON", _copy],
			["REBAKE\ncolours", _rebake_now], ["CLEAR ALL", _clear_all],
			["PLAY", _play]]:
		var b := Button.new()
		b.text = spec[0]
		b.custom_minimum_size = Vector2(168.0, 76.0)
		b.add_theme_font_size_override("font_size", 18)
		b.pressed.connect(spec[1])
		tool_bar.add_child(b)


func _pick_tool(t: int) -> void:
	tool_now = t as Tool
	for k in _tool_buttons:
		(_tool_buttons[k] as Button).button_pressed = k == t
	_refresh()


func _wire_sliders() -> void:
	brush_slider.min_value = 1.0
	brush_slider.max_value = 26.0
	brush_slider.value = brush_m
	brush_slider.value_changed.connect(func(v):
		brush_m = v
		_refresh())
	# 0..1 in the heightfield's own normalised space, the same numbers the
	# terrain ops and the passability thresholds are written in. Showing metres
	# here would be a second unit for the same thing.
	level_slider.min_value = 0.0
	level_slider.max_value = 1.0
	level_slider.step = 0.01
	level_slider.value = level
	level_slider.value_changed.connect(func(v):
		level = v
		_refresh())
	count_slider.min_value = 1.0
	count_slider.max_value = 12.0
	count_slider.step = 1.0
	count_slider.value = spawn_count
	count_slider.value_changed.connect(func(v):
		spawn_count = int(v)
		_refresh())


# --- editing -----------------------------------------------------------------
## One tap or one drag step. `continuous` is true while a finger is moving, and
## it is what stops a drag appending four hundred separate nest placements.
func _edit_at(p: Vector2, continuous: bool) -> void:
	match tool_now:
		Tool.RAISE:
			_stroke(p, absf(_stroke_amount()))
		Tool.LOWER:
			_stroke(p, -absf(_stroke_amount()))
		Tool.FLATTEN:
			_stamp({"op": "plateau", "x": p.x, "z": p.y, "r": brush_m,
				"level": level, "strength": 0.35 if continuous else 0.7})
		Tool.PLATEAU:
			if continuous:
				return
			_stamp({"op": "plateau", "x": p.x, "z": p.y, "r": brush_m,
				"level": level, "strength": 1.0})
		Tool.BLOCK:
			if continuous:
				return
			edit.add(&"blocked", {"x": p.x, "z": p.y, "r": brush_m})
			TerrainBuilder.apply_op(field, MapEdit.blocked_op(
				edit.blocked[-1], _impassable_level()))
			_after_shape()
		Tool.WALL:
			if continuous:
				return
			_wall_tap(p)
		Tool.PLANT:
			if continuous:
				return
			edit.add(&"plants", {"model": _plant_model(),
				"x": p.x, "z": p.y,
				"yaw": randf() * TAU, "scale": 0.85 + randf() * 0.5})
			_sync_plants()
			_touched()
		Tool.ROAMER:
			if continuous:
				return
			edit.add(&"roamers", {"x": p.x, "z": p.y,
				"wander_m": hive_cfg.roamer_wander_m})
			_touched()
		Tool.NEST:
			if continuous:
				return
			edit.add(&"nests", {"x": p.x, "z": p.y, "count": spawn_count,
				"interval_s": hive_cfg.plant_brood_interval_s})
			_touched()
		Tool.PATCH:
			if continuous:
				return
			edit.add(&"patches", {"x": p.x, "z": p.y, "count": spawn_count})
			_touched()
		Tool.ERASE:
			if continuous:
				return
			_erase_near(p)


## Tap out an outline, corner by corner.
##
## CLOSING BY TAPPING THE FIRST CORNER AGAIN is the only gesture a phone has
## for "done" that does not need a second hand, and it is what every drawing
## app on a touchscreen does. The CLOSE button exists as well, because the
## first corner is small and a fingertip is not.
func _wall_tap(p: Vector2) -> void:
	if _wall_pts.size() >= 3:
		var first: Vector2 = _wall_pts[0]
		if p.distance_to(first) <= maxf(3.0, brush_m * 0.5):
			_close_wall()
			return
	_wall_pts.append(p)
	_say("Corner %d. Tap the first one again, or press CLOSE."
		% _wall_pts.size())


func _close_wall() -> void:
	if _wall_pts.size() < 3:
		_say("A wall needs at least three corners; it has %d."
			% _wall_pts.size())
		return
	var w := {"points": _wall_pts.duplicate()}
	var probs := MapEdit.new()
	probs.add(&"walls", w)
	var bad := probs.problems(_map_w, _map_h)
	if not bad.is_empty():
		_say(bad[0])
		return
	edit.add(&"walls", w)
	_wall_pts.clear()
	# A wall touches no heights, so there is nothing to rebake and nothing to
	# mark dirty — the whole advantage of it being a separate mask.
	TerrainBuilder.apply_op(field, MapEdit.wall_op(w))
	_touched()
	_say("Wall closed.")


func _cancel_wall() -> void:
	if _wall_pts.is_empty():
		_say("No wall being drawn.")
		return
	_wall_pts.clear()
	_say("Dropped the wall you were drawing.")
	_refresh()


## How much one stroke step moves the ground. Scaled by the brush, because a
## wide brush moving as fast as a narrow one digs a canyon in one swipe.
func _stroke_amount() -> float:
	return 0.02 * clampf(brush_m / 6.0, 0.5, 2.0)


func _stroke(p: Vector2, amount: float) -> void:
	_stamp({"op": "crater", "x": p.x, "z": p.y, "r": brush_m,
		"amount": amount})


## Record an op AND apply it to the live field, so the ground moves under the
## finger. Rebuilding from the seed for every step is about a second on this
## map, which is a wait, not a brush.
func _stamp(op: Dictionary) -> void:
	edit.add(&"ops", op)
	TerrainBuilder.apply_op(field, op)
	_after_shape()


func _after_shape() -> void:
	terrain.mark_dirty()
	# The material classification and the baked shading are NOT redone here.
	# classify_materials plus the shade bake is about a second; doing it per
	# stroke would make the brush unusable. The shape is live, the colours lag,
	# and REBAKE catches them up — which is a fair trade as long as the lag is
	# visible, hence the readout.
	_rebake_due = true
	_touched()


func _touched() -> void:
	_dirty_since_save = true
	_refresh()


func _erase_near(p: Vector2) -> void:
	# Placements only. Erasing a sculpt stroke is UNDO's job: strokes overlap
	# and stack, so "the nearest one" is not a thing a finger can mean.
	var best_list := &""
	var best_i := -1
	var best_d := 9.0
	for pair in [[&"plants", edit.plants], [&"roamers", edit.roamers],
			[&"nests", edit.nests], [&"patches", edit.patches],
			[&"blocked", edit.blocked]]:
		# Walls are not in this list: a free-form outline has no single point
		# to be "nearest" to, and erasing the wall whose CORNER happens to be
		# closest is not what a finger over the middle of one means. UNDO takes
		# walls back.
		var arr: Array = pair[1]
		for i in arr.size():
			var d: float = Vector2(arr[i].x, arr[i].z).distance_to(p)
			if d < best_d:
				best_d = d
				best_list = pair[0]
				best_i = i
	if best_i < 0:
		_say("Nothing within %.0f m to erase." % best_d)
		return
	_remove(best_list, best_i)
	_say("Erased a %s." % String(best_list).trim_suffix("s"))


## Remove one entry and keep the undo history pointing at the right things.
## Rebuilds the world from scratch when it was a shape edit, because a hole
## cannot be un-dug incrementally.
func _remove(list_name: StringName, i: int) -> void:
	var arr: Array = edit.call("_list", list_name)
	if i < 0 or i >= arr.size():
		return
	arr.remove_at(i)
	for h in edit._history:
		if h[0] == list_name and int(h[1]) > i:
			h[1] = int(h[1]) - 1
		elif h[0] == list_name and int(h[1]) == i:
			h[1] = -1                       # dropped; undo will skip it
	if list_name == &"blocked" or list_name == &"walls":
		_replay()
	elif list_name == &"plants":
		_sync_plants()
	_touched()


func _undo() -> void:
	var gone := edit.undo()
	if gone.is_empty():
		_say("Nothing to undo.")
		return
	# A shape edit cannot be taken back in place — the field has no memory of
	# what was under the hole — so the world is rebuilt from the seed and the
	# remaining ops are replayed. Slow, and correct, and undo is not something
	# a finger holds down.
	_replay()
	_sync_plants()
	_say("Undone.")


## Rebuild the heightfield from the map's own seed and replay every edit.
##
## IN PLACE, into the field object the TerrainView already holds. The obvious
## version called terrain.setup() again — and setup() builds a NEW
## ShaderMaterial, while the chunk meshes keep a material_override pointing at
## the old one. The chunks are only ever built once (inside
## set_detail_scale_factor, of all places), so nothing rebinds them: the
## terrain would have gone quietly stale after the first undo, still drawing
## the heights it had before, with no error and no visible cause.
func _replay() -> void:
	var fresh := TerrainBuilder.build(load(MAP))
	for op in edit.all_ops(_impassable_level()):
		TerrainBuilder.apply_op(fresh, op)
	field.heights = fresh.heights
	field.water = fresh.water
	field.material_id = fresh.material_id
	field.blocked = fresh.blocked
	_rebake()
	_sync_plants()
	_touched()


func _rebake() -> void:
	TerrainBuilder.classify_materials(field, palette.void_below,
		palette.channel_below, palette.channel_web_threshold, 2.5, 3.0,
		palette.channel_strand_width_m)
	terrain.apply_palette(palette)
	terrain.set_sun(load(LIGHT_CFG))
	terrain.mark_dirty()
	_rebake_due = false


func _rebake_now() -> void:
	_rebake()
	_say("Colours and shading caught up with the shape.")
	_refresh()


func _impassable_level() -> float:
	# One metre of margin under the threshold, in normalised units, so a
	# blocked disc is unambiguously impassable rather than exactly on the line.
	return maxf(0.0, field.cfg.impassable_below - 0.05)


func _plant_model() -> String:
	# Whatever the dressing calls its alien plants, so a hand-placed nest plant
	# is the same model the Hive picks its nests from.
	var plan: BiomeDressing = load(DRESSING)
	for e in plan.entries:
		if "brain" in String(e.model) or "flora" in String(e.model):
			return e.model
	return plan.entries[0].model if not plan.entries.is_empty() else ""


# --- showing it --------------------------------------------------------------
func _sync_plants() -> void:
	for n in _plant_nodes:
		n.queue_free()
	_plant_nodes.clear()
	for p in edit.plants:
		var n: Node3D = _lib.spawn(String(p.get("model", "")))
		if n == null:
			continue
		var at := Vector2(p.x, p.z)
		n.position = Vector3(at.x, terrain.height_at(at), at.y)
		n.rotation.y = float(p.get("yaw", 0.0))
		n.scale = Vector3.ONE * float(p.get("scale", 1.0))
		add_child(n)
		_plant_nodes.append(n)


## Discs on the ground for everything that is not a plant: the placements have
## no model, and a marker the same colour for all of them would be a map of
## dots nobody can read.
func _markers() -> Array:
	var out: Array = []
	# Finished walls, as a chain of dots along the outline. Dots rather than a
	# filled shape because a wall is INVISIBLE in the game and the editor must
	# not make it look like a floor decal the player will see.
	for w in edit.walls:
		_outline(out, MapEdit.wall_points(w), Color(0.98, 0.84, 0.22, 0.85),
			true)
	# And the one being drawn, in a different colour, so an unclosed wall is
	# obviously unfinished rather than obviously broken.
	if not _wall_pts.is_empty():
		var live := PackedVector2Array()
		for p in _wall_pts:
			live.append(p)
		_outline(out, live, Color(0.30, 0.95, 1.0, 0.95), false)
	for b in edit.blocked:
		out.append({"pos": Vector2(b.x, b.z), "r": float(b.r),
			"col": Color(0.95, 0.20, 0.24, 0.5)})
	for r in edit.roamers:
		out.append({"pos": Vector2(r.x, r.z),
			"r": float(r.get("wander_m", 26.0)),
			"col": Color(1.0, 0.45, 0.16, 0.16)})
		out.append({"pos": Vector2(r.x, r.z), "r": 2.4,
			"col": Color(1.0, 0.55, 0.20, 0.85)})
	for n in edit.nests:
		out.append({"pos": Vector2(n.x, n.z), "r": hive_cfg.plant_notice_m,
			"col": Color(0.65, 0.30, 0.95, 0.18)})
		out.append({"pos": Vector2(n.x, n.z), "r": 1.6,
			"col": Color(0.78, 0.42, 1.0, 0.9)})
	for q in edit.patches:
		out.append({"pos": Vector2(q.x, q.z), "r": hive_cfg.patch_notice_m,
			"col": Color(0.25, 0.85, 0.95, 0.20)})
		out.append({"pos": Vector2(q.x, q.z), "r": 1.1,
			"col": Color(0.35, 0.95, 1.0, 0.9)})
	return out


## Dot the corners of an outline and the spans between them, so a wall reads as
## a closed shape rather than a scatter of points. `closed` joins the last
## corner back to the first; a wall still being drawn is deliberately left open.
func _outline(out: Array, pts: PackedVector2Array, col: Color,
		closed: bool) -> void:
	var n := pts.size()
	if n == 0:
		return
	for i in n:
		out.append({"pos": pts[i], "r": 1.0, "col": col})
		if i == n - 1 and not closed:
			break
		var a := pts[i]
		var b := pts[(i + 1) % n]
		# One dot every two metres along the span. Enough to read as a line at
		# the editor's camera height without flooding the marker budget.
		var steps := maxi(1, int(a.distance_to(b) / 2.0))
		for k in range(1, steps):
			out.append({"pos": a.lerp(b, float(k) / steps), "r": 0.5,
				"col": Color(col.r, col.g, col.b, col.a * 0.6)})


func _marker_mesh() -> Mesh:
	var m := CylinderMesh.new()
	m.top_radius = 1.0
	m.bottom_radius = 1.0
	m.height = 0.05
	m.radial_segments = 24
	m.rings = 0
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.material = mat
	return m


func _process(delta: float) -> void:
	_ease_zoom(delta)
	var mm := _mm_marks.multimesh
	var n := 0
	for m in _markers():
		if n >= mm.instance_count:
			break
		var p: Vector2 = m.pos
		var r: float = m.r
		mm.set_instance_transform(n, Transform3D(
			Basis.IDENTITY.scaled(Vector3(r, 0.05, r)),
			Vector3(p.x, terrain.height_at(p) + 0.2, p.y)))
		mm.set_instance_color(n, m.col)
		n += 1
	mm.visible_instance_count = n
	# THE FOG HAS TO BE UPLOADED, every frame, even though the editor hides
	# nothing. The terrain shader samples fog_map unconditionally, so a fog
	# that is never uploaded reads as all-zero — which means "never explored",
	# which means the whole map renders as void. The first editor frame came
	# back solid black with a perfectly correct HUD on top of it.
	terrain.fog.begin_frame()
	terrain.fog.reveal(Vector2(_map_w * 0.5, _map_h * 0.5),
		maxf(_map_w, _map_h))
	terrain.fog.upload(delta)
	terrain.upload()


func _refresh() -> void:
	readout.text = "%s        brush %.0f m    level %.2f    spawns %d%s" \
		% [TOOL_LABEL[tool_now].replace("\n", " "), brush_m, level,
			spawn_count, "    COLOURS STALE" if _rebake_due else ""]
	brush_label.text = "BRUSH %.0f m" % brush_m
	level_label.text = "LEVEL %.2f" % level
	count_label.text = "SPAWNS %d" % spawn_count


func _say(text: String) -> void:
	status.text = "%s        %s%s" % [text, edit.summary(),
		"        UNSAVED" if _dirty_since_save else ""]


# --- getting it out ----------------------------------------------------------
func _save() -> void:
	var problems := edit.problems(_map_w, _map_h)
	if not problems.is_empty():
		_say("Will not save: " + problems[0])
		return
	var err := edit.save_to(SAVE_PATH)
	if err != "":
		_say(err)
		return
	_dirty_since_save = false
	# The ABSOLUTE path, because "user://" is not somewhere anyone can look.
	_say("Saved to %s" % ProjectSettings.globalize_path(SAVE_PATH))


## The way off the phone that does not need a file manager.
##
## An Android app's user:// lives inside its own sandbox, where nothing else
## can reach it — so on the platform this editor is FOR, the saved file is the
## least useful of the two outputs. The clipboard goes straight into a chat
## window, which is where the JSON is going anyway.
func _copy() -> void:
	var problems := edit.problems(_map_w, _map_h)
	if not problems.is_empty():
		_say("Will not copy: " + problems[0])
		return
	DisplayServer.clipboard_set(edit.to_json())
	_say("JSON on the clipboard — %d characters. Paste it in chat."
		% edit.to_json().length())


func _clear_all() -> void:
	edit.clear()
	_replay()
	_say("Cleared everything.")


func _play() -> void:
	get_tree().change_scene_to_file("res://scenes/proto/proto_main.tscn")


# --- camera and input --------------------------------------------------------
var _zoom := 1.0
var _zoom_step := 0
var _touches: Dictionary = {}
var _pinch_from := 0.0
var _pinch_zoom := 1.0
var _painting := false
var _panning := false
var _press := Vector2.ZERO


## The editor's camera is the game's camera PULLED BACK. Same pitch, same
## field of view, same zoom rungs — the map has to be judged at the angle it is
## played at — but the game frames one lobe and an editor has to see what it is
## editing. 2.4x is what it takes to get 112 m of map inside a 58-degree
## vertical view; the rungs then step in from there to the play framing.
const EDITOR_WIDE := 2.4


func _frame_camera() -> void:
	rig.position.y = terrain.height_at(Vector2(rig.position.x, rig.position.z))
	camera.position = tune.camera_offset * _zoom * EDITOR_WIDE
	camera.look_at(rig.global_position, Vector3.UP)
	camera.fov = tune.camera_fov_deg


func _ease_zoom(delta: float) -> void:
	var want: float = tune.camera_zoom_steps[clampi(_zoom_step, 0,
		tune.camera_zoom_steps.size() - 1)]
	if absf(_zoom - want) < 0.001:
		return
	_zoom = lerpf(_zoom, want, clampf(tune.camera_zoom_lerp * delta, 0.0, 1.0))
	_frame_camera()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_touch(event)
	elif event is InputEventScreenDrag:
		_touches[event.index] = event.position
		if _touches.size() >= 2:
			_pinch()
		elif _painting:
			_drag(event)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_step_zoom(-1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_step_zoom(1)


func _touch(e: InputEventScreenTouch) -> void:
	if e.pressed:
		_touches[e.index] = e.position
		if _touches.size() == 2:
			# Two fingers is the camera, never the brush. Without this, pinching
			# to look closer also carves a hole where the first finger landed.
			_painting = false
			_panning = false
			_pinch_from = _spread()
			_pinch_zoom = _zoom
		elif _touches.size() == 1:
			_painting = true
			_panning = false
			_press = e.position
		return
	_touches.erase(e.index)
	if _touches.is_empty():
		if _painting and not _panning:
			var p: Variant = _ground(e.position)
			if p != null:
				_edit_at(p as Vector2, false)
				_say("Placed.")
		elif not _painting:
			_settle_zoom()
		_painting = false
		_panning = false
	elif _touches.size() == 1:
		_painting = false
		_panning = true


## A drag is a PAN unless the tool paints. Sculpting wants a stroke; placing a
## nest wants to move the map, and a one-finger drag is the only gesture a
## phone has left once pinch is taken.
func _drag(e: InputEventScreenDrag) -> void:
	if _press.distance_to(e.position) > 14.0:
		_panning = true
	if not _panning:
		return
	if _paints():
		var p: Variant = _ground(e.position)
		if p != null:
			_edit_at(p as Vector2, true)
		return
	rig.position += Vector3(-e.relative.x, 0.0, -e.relative.y) * 0.09 * _zoom
	_frame_camera()


func _paints() -> bool:
	return tool_now == Tool.RAISE or tool_now == Tool.LOWER \
		or tool_now == Tool.FLATTEN


func _ground(screen: Vector2) -> Variant:
	var hit: Variant = terrain.raycast(camera.project_ray_origin(screen),
		camera.project_ray_normal(screen))
	if hit == null:
		return null
	var h: Vector3 = hit
	return Vector2(h.x, h.z)


func _spread() -> float:
	var pts: Array = _touches.values()
	if pts.size() < 2:
		return 0.0
	return (pts[0] as Vector2).distance_to(pts[1] as Vector2)


func _pinch() -> void:
	var now := _spread()
	if _pinch_from < tune.pinch_deadzone_px or now < tune.pinch_deadzone_px:
		return
	_zoom = clampf(_pinch_zoom / (now / _pinch_from), _zoom_low(), _zoom_high())
	_frame_camera()


func _step_zoom(by: int) -> void:
	_zoom_step = clampi(_zoom_step + by, 0,
		tune.camera_zoom_steps.size() - 1)


func _settle_zoom() -> void:
	var best := 0
	var bd := 1.0e9
	for i in tune.camera_zoom_steps.size():
		var d: float = absf(tune.camera_zoom_steps[i] - _zoom)
		if d < bd:
			bd = d
			best = i
	_zoom_step = best


func _zoom_low() -> float:
	var m := 1.0
	for z in tune.camera_zoom_steps:
		m = minf(m, z)
	return m


func _zoom_high() -> float:
	var m := 0.0
	for z in tune.camera_zoom_steps:
		m = maxf(m, z)
	return maxf(m, 0.01)
