extends Node3D
## SENTINEL — first minutes of the mass loop. See docs/loop-v2.md.
##
## The loop: drone collects small debris -> module grows -> spend mass to build
## (module shrinks) -> free a stuck large piece -> that starts the attacks ->
## hold until it comes free -> attacks stop, mass banked. Wrecks are recovered
## by the drone and become mass again, minus a loss.
##
## One file on purpose: this is a prototype, and a reader six months from now
## should be able to follow the whole loop without chasing six scripts. The
## rules worth protecting live in tested systems (MassPool, WaveDirector,
## FogOfWar); what is here is wiring and presentation.

const MAP := "res://data/terrain/biodome_map_01.tres"
const PALETTE := "res://data/biomes/biodome_01_palette.tres"
const DRESSING := "res://data/biomes/biodome_01_dressing.tres"
const MASS_CFG := "res://data/gameplay/mass.tres"
const WAVES := "res://data/waves/biodome_01.tres"
const HIVE := "res://data/gameplay/hive.tres"
## Hand-placed alien and plant positions, written by tools/apply_map_edit.
## Optional: the map is fully procedural until a map edit is applied.
const PLACEMENTS := "res://data/gameplay/hive_placements.tres"
const OPTIONS_DIR := "res://data/gameplay/build_options/"
const TERRAIN_SHADER := "res://shaders/terrain_lit.gdshader"
const LIGHT_CFG := "res://data/gameplay/lighting.tres"

const MACHINE_RULES := "res://data/gameplay/machines.tres"
const MERGE_RULES := "res://data/gameplay/merge.tres"
## Two presets, so the phone test can MEASURE what the expensive one costs
## instead of guessing. Not a settings menu — instrumentation.
## Three rungs, not two, so a failure is DIAGNOSTIC. If High misses the frame
## budget and Medium holds it, the cost was 4x MSAA; if Medium misses too, it
## is the terrain shader or the prop count. Two presets would only say "the
## expensive one is expensive".
const RAVINE := "res://data/biomes/biodome_01_ravine.tres"
const QUALITY := ["res://data/gameplay/quality_high.tres",
	"res://data/gameplay/quality_medium.tres",
	"res://data/gameplay/quality_low.tres"]
const PROTO_CFG := "res://data/gameplay/proto.tres"
const EFFECTS := "res://data/gameplay/effects.tres"
const FOG_HZ := 15.0        ## presentation cadence, not a gameplay number
## `dying` when a thing is not dying. See _add_alien for why it is not zero.
const ALIVE := -1.0
## Scenery is bucketed into squares this big so the frustum can cull it. See
## _dress — the number is a draw-calls-versus-wasted-triangles tradeoff, not a
## gameplay knob, which is why it lives here and not in a .tres.
const BUCKET_M := 48.0

@onready var terrain: TerrainView = $Terrain
@onready var module: Node3D = $Module
@onready var drone: Node3D = $Drone
@onready var rig: Node3D = $CameraRig
@onready var sun: DirectionalLight3D = $Sun
@onready var world_env: WorldEnvironment = $WorldEnvironment
@onready var camera: Camera3D = $CameraRig/Camera3D
@onready var mass_label: Label = $HUD/TopBar/Row/Mass/Label
@onready var mass_bar: ProgressBar = $HUD/TopBar/Row/Mass/Bar
@onready var seen_label: Label = $HUD/TopBar/Row/Mass/Seen
@onready var mode_label: Label = $HUD/TopBar/Row/Mode
@onready var tally_label: Label = $HUD/TopBar/Row/Tally
@onready var mini: MiniMap = $HUD/Mini
@onready var alert_label: Label = $HUD/Alert/Line
@onready var job_bar: ProgressBar = $HUD/Alert/Job
@onready var toast: Label = $HUD/Alert/Toast
@onready var strip_label: Label = $HUD/Strip/Text
@onready var radar_label: Label = $HUD/Side/Radar/Text
@onready var target_panel: Control = $HUD/Target
@onready var target_label: Label = $HUD/Target/Text
@onready var build_bar: GridContainer = $HUD/Side/BuildScroll/Build
@onready var perf_label: Label = $HUD/Perf/Readout
@onready var perf_panel: Control = $HUD/Perf
@onready var forge_panel: Control = $HUD/Forge
@onready var forge_bar: HBoxContainer = $HUD/Forge/Col/Scroll/Row

var field: Heightfield
var fog: FogOfWar
var mass: MassPool
var waves: WaveDirector
var options: Array[BuildOption] = []
var rules: MachineRules
var forge: MergeRules
var palette: BiomePalette
var ink: InkPass
var quality: QualityConfig
var _quality_slot := 0
## Resolved machine numbers, keyed by build-option id. Resolved once at load
## because a loadout is fixed: the parts a machine was built with are the parts
## it dies with. Everything in the sim reads these, never a part or a chassis.
var specs: Dictionary = {}
var tune: ProtoConfig
var fx: EffectsConfig

var module_pos := Vector2.ZERO
## Where the player last tapped. The module drives toward it; see _walk_module.
var module_goal := Vector2.ZERO
var drone_pos := Vector2.ZERO
var drone_state := "idle"          # idle | outbound | working | returning
var drone_target := -1
var drone_cargo := 0.0
var drone_cargo_is_wreck := false
var free_progress := 0.0

var debris: Array[Dictionary] = []
var built: Array[Dictionary] = []
## Machines whose mass is already committed but which do not exist yet. This is
## the entire cost of repurposing: mass is conserved, so the only thing a
## rebuild can charge is the seconds it spends here and the hole in the line
## while it waits.
var assembling: Array[Dictionary] = []
## Merge orders in flight. A machine is mass in a shape, and this is where one
## shape becomes another: the group walks to a rendezvous, meets, and reforges.
var merging: Array[Dictionary] = []
## Machines the player has tapped, by uid. Indices would go stale the moment
## anything died.
var selected: Array[int] = []
var _next_uid := 1
var aliens: Array[Dictionary] = []
## Ids are handed out once and never reused. The Hive holds ids rather than
## indices because dead aliens are removed and every index after them shifts.
var _next_alien_uid := 1
var hive: Hive
var hive_cfg: HiveConfig
## Where the dressing put the alien plants, for the Hive to choose nests from.
var _plant_spots: Array[Vector2] = []
var wrecks: Array[Dictionary] = []
## Shots in the air. A firefight used to be two groups of models standing still
## while one of them quietly lost, because damage landed the instant a cooldown
## came up and nothing ever crossed the gap.
##
## Each entry: {pos, from, aim, target(uid), damage, splash_m, speed, family,
## flown, span}. The TARGET IS AN ID, not an index — aliens leave the array
## from the middle constantly and an index-carrying shot would arrive at
## whoever had shuffled into that slot.
var shots: Array[Dictionary] = []

var _mm_debris: MultiMeshInstance3D
var _mm_built: MultiMeshInstance3D
var _mm_aliens: MultiMeshInstance3D
var _mm_marks: MultiMeshInstance3D
var _mm_shots: MultiMeshInstance3D
var _mm_bars: MultiMeshInstance3D
var _module_scale := 1.0
var _toast_t := 0.0
var _fog_cd := 0.0
var _scenery_dirty := true
## Frame-time instrumentation. Always sampling, shown only when asked — the
## numbers have to cover the whole session, not just the bit after the player
## remembered to open the panel.
var probe := FrameProbe.new()
var _scenery_drawn := 0
var _scenery_total := 0
var _forge_sig := ""
var trenching := false
## Which of the three zoom rungs is selected, and where the camera actually is
## between them. Two variables because the second eases toward the first —
## snapping the camera is disorienting on a map navigated by landmark.
var zoom_step := 0
var _zoom := 1.0
var _zoom_button: Button = null
## Camera shake: how far it is still allowed to move, and how long it has been
## going. Decays to nothing and costs not one draw call.
var _shake := 0.0
var _shake_t := 0.0
var _module_flash := 0.0
var _fx_mode := 0
var _fx_button: Button = null
## The two lighting experiments the phone has to settle, because this machine
## cannot: see _cycle_lights.
var _area_fill: AreaLight3D = null
var _canopy_light: SpotLight3D = null
var _light_mode := 0        ## 0 base, 1 canopy, 2 area fill, 3 both
var _light_button: Button = null
var _rng := RandomNumberGenerator.new()
var lib := ModelLibrary.new()
var _module_body: Node3D = null
var _module_form := -1
## uid -> Node3D. See _sync_convoy for why this is not an array.
var _unit_nodes: Dictionary = {}
var _alien_nodes: Array[Node3D] = []
## One entry per prop kind: {mmi, spots}. See _dress.
var _scenery: Array[Dictionary] = []


func _ready() -> void:
	_rng.seed = 20260913
	tune = load(PROTO_CFG)
	fx = load(EFFECTS)
	# BEFORE the library spawns anything. apply_painted mutates the shared
	# cached mesh resources the first time a model is asked for, so a sway set
	# afterwards reaches nothing that already exists.
	ModelLibrary.painted_sway_m = fx.sway_m if fx.vine_wind else 0.0
	ModelLibrary.painted_sway_hz = fx.sway_hz
	ModelLibrary.painted_sway_ref_h = fx.sway_ref_h
	# Final-quality lighting, applied from data. Frame-rate work measured
	# without shadows and a lit sky measures a game nobody ships.
	LightingRig.apply(load(LIGHT_CFG), sun, world_env)
	var map: TerrainMap = load(MAP)
	field = TerrainBuilder.build(map)
	var cfg := field.cfg

	fog = FogOfWar.new(Vector2i(cfg.cells_x, cfg.cells_z), cfg.cell_size_m)
	terrain.setup(field, fog, load(TERRAIN_SHADER))
	palette = load(PALETTE)
	# What the ground is MADE OF, decided from the shape the ops left behind.
	# Explicit rather than folded into TerrainBuilder.build(), because it needs
	# the palette's world edge and the palette is a look, not a shape — one
	# call, one source for that number.
	# Hand the model library the ground's own tone ramp BEFORE anything spawns,
	# so every prop, plant and machine is lit by the same model as the terrain.
	lib.painted_ramp = TerrainView.ramp_texture(palette)
	lib.painted_ink = palette.prop_rim_ink
	lib.painted_machine_detail = palette.machine_detail
	lib.painted_scale_detail = palette.scale_detail
	TerrainBuilder.classify_materials(field, palette.void_below, palette.channel_below,
		palette.channel_web_threshold, 2.5, 3.0, palette.channel_strand_width_m)
	terrain.apply_palette(palette)
	terrain.set_sun(load(LIGHT_CFG))
	# The ravine the map sits in. Added before anything else so it is the first
	# opaque thing behind the terrain in the depth sort. It is what shows
	# through every fragment the terrain shader discards, so without it the
	# notches and the surround render as clear colour.
	add_child(RavineWall.build(load(RAVINE),
		Vector2(cfg.cells_x * cfg.cell_size_m, cfg.cells_z * cfg.cell_size_m),
		TerrainView.ramp_texture(palette),
		LightingRig.sun_ground_dir(load(LIGHT_CFG))))
	# Moonlight through the biodome's canopy. The moon itself cannot carry a
	# cookie — DirectionalLight3D has no projector slot — so this is its own
	# shadowless spot whose only job is the pattern. See CanopyLight.
	_canopy_light = CanopyLight.build(palette,
		Vector2(cfg.cells_x * cfg.cell_size_m, cfg.cells_z * cfg.cell_size_m),
		true)
	if _canopy_light != null:
		add_child(_canopy_light)
	# The soft overhead fill. AreaLight3D is new in 4.7 and Mobile runs it;
	# see LightingRig.build_area_fill for why this is the only new tool that
	# adds indirect-looking light without a feature Mobile refuses. Off in the
	# shipped .tres — the LIGHTS button turns it on so the phone can MEASURE
	# what it costs instead of us guessing.
	# force: build it even though the .tres has it off, hidden, so the LIGHTS
	# button can switch it on. A light that was never built cannot be toggled.
	_area_fill = LightingRig.build_area_fill(load(LIGHT_CFG),
		Vector2(cfg.cells_x * cfg.cell_size_m, cfg.cells_z * cfg.cell_size_m),
		terrain.height_at(map.spawn), true)
	if _area_fill != null:
		add_child(_area_fill)
	# Reflection probes on the pools, found from the water mask. One of the
	# two GI features Forward Mobile will run; see WaterProbes for why the
	# other one, LightmapGI, cannot be used on this map at all.
	for rp in WaterProbes.build(field, palette):
		add_child(rp)
	ink = InkPass.build()
	ink.apply(palette)
	add_child(ink)
	mini.bind(fog, Vector2(cfg.cells_x * cfg.cell_size_m, cfg.cells_z * cfg.cell_size_m))

	mass = MassPool.new(load(MASS_CFG))
	mass.rejected.connect(func(why): _say(why))
	waves = WaveDirector.new(load(WAVES))
	waves.spawn_due.connect(_spawn_hostiles)
	waves.wave_began.connect(func(_s, _i): _say("THEY HAVE NOTICED — hold until it is free"))
	waves.wave_ended.connect(func(_s): _say("THE PIECE IS FREE — the attack breaks off"))

	# THE HIVE. Two creatures in the open and everything else underground until
	# the player wakes it: see HiveConfig for the four ways that happens and
	# the off switch each one has.
	hive_cfg = load(HIVE)
	hive = Hive.new(hive_cfg, field, 20260918)
	# Hand-placed layout from the map editor, if one has been applied. Absent
	# is the normal state and means "scatter it all", so nothing breaks before
	# a map has ever been edited.
	if ResourceLoader.exists(PLACEMENTS):
		hive.placed = load(PLACEMENTS)
	hive.brood_due.connect(_brood)
	hive.woke.connect(_hive_woke)
	_load_options()
	module_pos = map.spawn
	module_goal = module_pos
	drone_pos = module_pos + Vector2(3.0, 0.0)
	_scatter_debris()
	_dress(map.spawn)
	# AFTER the dressing, because the plant nests are chosen from the plants it
	# just placed, and after the debris so a patch does not land under a piece.
	_populate_hive(map.spawn)
	_make_instancers()
	_build_menu()

	(module.get_node("Hull") as MeshInstance3D).queue_free()
	(drone.get_node("Body") as MeshInstance3D).queue_free()
	_set_module_form(0)
	var d := lib.spawn(tune.drone_model)
	if d != null:
		drone.add_child(d)

	_module_scale = mass.display_scale()
	module.scale = Vector3.ONE * _module_scale
	rig.position = Vector3(module_pos.x, 0.0, module_pos.y)
	_frame_camera()
	# After LightingRig, which is what makes the quality preset authoritative
	# for the two settings they both touch.
	_apply_quality(0)
	probe.reset()
	perf_panel.visible = false
	_say("A module. A drone. Debris. Start there.")


## Swap the module to the growth form matching its mass. The three forms share
## a silhouette and grow by accreting plate, so this reads as the same machine
## getting bigger rather than a different model appearing.
func _set_module_form(form: int) -> void:
	form = clampi(form, 0, tune.module_forms.size() - 1)
	if form == _module_form:
		return
	_module_form = form
	if _module_body != null:
		_module_body.queue_free()
	_module_body = lib.spawn(tune.module_model, tune.module_forms[form])
	if _module_body != null:
		module.add_child(_module_body)


## Which growth form the current mass earns.
func _form_for_mass() -> int:
	var t := mass.normalized()
	if t < 0.18:
		return 0
	return 1 if t < 0.45 else 2


func _load_options() -> void:
	rules = load(MACHINE_RULES)
	forge = load(MERGE_RULES)
	for f in DirAccess.get_files_at(OPTIONS_DIR):
		if f.ends_with(".tres"):
			options.append(load(OPTIONS_DIR + f))
	options.sort_custom(func(a, b): return a.mass_cost < b.mass_cost)
	for opt in options:
		var spec := opt.spec(rules)
		if not spec.is_valid():
			push_error("%s: %s" % [opt.id, ", ".join(spec.errors)])
		specs[opt.id] = spec


## The machine numbers for one option. Never null: a flat option resolves to a
## spec too, so the sim has exactly one shape to handle.
func spec_for(opt: BuildOption) -> MachineSpec:
	if not specs.has(opt.id):
		specs[opt.id] = opt.spec(rules)
	return specs[opt.id]


## Small pieces near the crash, large ones further out. The player starts with
## everything they need in reach and has to choose to go looking for more.
func _scatter_debris() -> void:
	for i in tune.small_count:
		var a := _rng.randf() * TAU
		var d := lerpf(tune.small_spread_m.x, tune.small_spread_m.y, _rng.randf())
		_add_debris(module_pos + Vector2(cos(a), sin(a)) * d, false)
	for i in tune.large_count:
		var a := _rng.randf() * TAU
		var d := lerpf(tune.large_spread_m.x, tune.large_spread_m.y, _rng.randf())
		_add_debris(module_pos + Vector2(cos(a), sin(a)) * d, true)


func _add_debris(p: Vector2, large: bool) -> void:
	var cfg := field.cfg
	p.x = clampf(p.x, 4.0, cfg.cells_x - 4.0)
	p.y = clampf(p.y, 4.0, cfg.cells_z - 4.0)
	debris.append({
		"pos": p, "large": large, "taken": false,
		"mass": tune.large_mass if large else tune.small_mass,
	})


## Grow the biodome. Scenery is placed once from a seed and never moves, so it
## costs one scatter pass at load and six draw calls a frame thereafter.
##
## MultiMesh rather than nodes: a couple of hundred props as individual nodes
## is a couple of hundred draw calls, which is the whole budget on a phone
## before anything in the game has drawn. Skinned meshes cannot go through a
## MultiMesh — none of these are skinned, which is why they were built as one
## mesh each.
func _dress(landing: Vector2) -> void:
	var plan: BiomeDressing = load(DRESSING)
	if plan == null:
		return
	var placed := Dressing.place(field, plan, landing)
	# The alien plants, kept for the Hive to pick nests from. A nest is always
	# a plant the player can see and walk up to, never an invisible box that
	# happens to sit near one.
	_plant_spots.clear()
	for t in placed.get(&"flora_brain", []):
		var tr: Transform3D = t
		_plant_spots.append(Vector2(tr.origin.x, tr.origin.z))
	for entry in plan.entries:
		var spots: Array = placed.get(entry.model, [])
		if spots.is_empty():
			continue
		var mesh := lib.biggest_mesh(String(entry.model))
		if mesh == null:
			push_warning("dressing: no mesh for '%s'" % entry.model)
			continue
		# Bucketed by a coarse grid rather than one MultiMesh per prop kind.
		# Godot frustum-culls a MultiMesh as a single object, so one instancer
		# covering the whole map submits every prop on it whichever way the
		# camera is pointing — four hundred props' worth of triangles for the
		# dozen actually on screen. A bucket is a few draw calls' worth of
		# bookkeeping to make that culling work.
		var buckets := {}
		for t in spots:
			var tr: Transform3D = t
			var key := Vector2i(int(tr.origin.x / BUCKET_M), int(tr.origin.z / BUCKET_M))
			if not buckets.has(key):
				buckets[key] = []
			buckets[key].append(tr)
		for key in buckets:
			var group: Array = buckets[key]
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = MultiMesh.new()
			mmi.multimesh.transform_format = MultiMesh.TRANSFORM_3D
			mmi.multimesh.mesh = mesh
			mmi.multimesh.instance_count = group.size()
			mmi.multimesh.visible_instance_count = 0
			# Shadow casting is the expensive half — every instance is drawn
			# again into the atlas — so only the props big enough for a missing
			# shadow to read as floating pay for it.
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON \
				if entry.casts_shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
			add_child(mmi)
			_scenery_total += group.size()
			_scenery.append({"mmi": mmi, "spots": group})


## Submit only the scenery the player has actually uncovered.
##
## Explored, not visible: geology is remembered. An arch you walked past stays
## on the map when you walk away, the way the ground under it does — it is only
## live contacts that vanish when nothing is watching.
func _cull_scenery() -> void:
	var drawn := 0
	for group in _scenery:
		var mmi: MultiMeshInstance3D = group.mmi
		var n := 0
		for t in group.spots:
			var tr: Transform3D = t
			if fog.level_at(Vector2(tr.origin.x, tr.origin.z)) <= 0.0:
				continue
			mmi.multimesh.set_instance_transform(n, tr)
			n += 1
		mmi.multimesh.visible_instance_count = n
		drawn += n
	_scenery_drawn = drawn


func _make_instancers() -> void:
	_mm_debris = _instancer(_chunk_mesh(Color(0.85, 0.74, 0.42)), 64)
	_mm_built = _instancer(_chunk_mesh(Color(0.31, 0.89, 0.76)), 96)
	_mm_aliens = _instancer(_chunk_mesh(Color(1.0, 0.36, 0.45)), 192)
	_mm_marks = _instancer(_ring_mesh(), 256)
	_mm_marks.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Shots and bars are UNLIT. Both have to read against a dark ground at a
	# glance on a phone, and both are information rather than objects — a
	# tracer that the moon fails to catch is a tracer nobody sees.
	_mm_shots = _instancer(_flat_mesh(true), tune.shot_cap)
	_mm_shots.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Two instances per bar, back and fill, plus the module's own.
	_mm_bars = _instancer(_flat_mesh(false), 320)
	_mm_bars.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## A flat glowing disc under a selected machine. Unlit and emissive so it reads
## on a phone in a dark biodome without competing with the unit itself.
func _ring_mesh() -> Mesh:
	var m := CylinderMesh.new()
	m.top_radius = 1.0
	m.bottom_radius = 1.0
	m.height = 0.06
	m.radial_segments = 20
	m.rings = 0
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.86, 0.35, 0.55)
	m.material = mat
	return m


## A unit quad or box, unshaded, coloured per instance.
##
## `glow` is the difference between a tracer and a health bar: a tracer wants
## to bloom, a bar wants to stay a flat readable strip and not smear into the
## thing it is describing.
func _flat_mesh(glow: bool) -> Mesh:
	var m := BoxMesh.new()
	m.size = Vector3.ONE
	# OPAQUE, and no no_depth_test. The first version of this was an alpha
	# material with depth testing disabled, which submitted perfectly — right
	# AABB, right transforms, visible_instance_count set — and drew NOTHING on
	# the Mobile renderer. Every exotic flag here was one the rest of the
	# project does not use anywhere else, and none of them were load-bearing:
	# a bar wants to be a flat readable strip, which opaque does better anyway.
	# Bars clear the models by floating above them instead.
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if glow:
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.86, 0.55)
		mat.emission_energy_multiplier = 2.4
	m.material = mat
	return m


func _chunk_mesh(c: Color) -> Mesh:
	var m := BoxMesh.new()
	m.size = Vector3(0.9, 0.9, 0.9)
	# The painted shader, like everything else on screen. These are built here
	# rather than loaded through ModelLibrary, so they missed the material swap
	# and stayed on default Lambert — which on this dim moon rig meant the
	# debris and the alien swarm rendered as black boxes while the ground and
	# the machines beside them did not. Two lighting models was the bug; this
	# is the last thing that was still on the second one.
	var sm := ShaderMaterial.new()
	sm.shader = load(ModelLibrary.PAINTED_SHADER)
	sm.set_shader_parameter("albedo", c)
	sm.set_shader_parameter("roughness_v", 0.7)
	sm.set_shader_parameter("use_vertex_colour", false)
	sm.set_shader_parameter("tone_ramp", TerrainView.ramp_texture(palette))
	sm.set_shader_parameter("rim_ink", palette.prop_rim_ink)
	m.material = sm
	return m


func _instancer(mesh: Mesh, cap: int) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = MultiMesh.new()
	mmi.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	mmi.multimesh.use_colors = true
	mmi.multimesh.mesh = mesh
	mmi.multimesh.instance_count = cap
	mmi.multimesh.visible_instance_count = 0
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(mmi)
	return mmi


## Thumb-sized tiles in the right-hand column, as in the mockup. The column
## scrolls vertically, so the catalogue can grow without the tiles shrinking.
## Two columns inside a 366-wide side panel, with a 10 px gutter.
const BUTTON_MIN := Vector2(174.0, 92.0)


func _build_menu() -> void:
	# FIRST, before TRENCH. Zoom is a control the player reaches for constantly
	# while reading the map, not instrumentation like PERF — it does not belong
	# at the bottom of a column that scrolls.
	_zoom_button = Button.new()
	_zoom_button.custom_minimum_size = BUTTON_MIN
	_zoom_button.add_theme_font_size_override("font_size", 19)
	_zoom_button.pressed.connect(func():
		cycle_zoom()
		_refresh_zoom_button())
	build_bar.add_child(_zoom_button)
	_refresh_zoom_button()

	var dig := Button.new()
	dig.text = "TRENCH\nfree"
	dig.toggle_mode = true
	dig.custom_minimum_size = BUTTON_MIN
	dig.add_theme_font_size_override("font_size", 19)
	dig.toggled.connect(func(on): trenching = on)
	build_bar.add_child(dig)
	for opt in options:
		var spec := spec_for(opt)
		var b := Button.new()
		# Role first: the player is choosing an army shape, not a unit name.
		b.text = "%s\n%s  %d" % [opt.display_name, spec.role_name().left(4), int(spec.mass)]
		b.tooltip_text = _machine_card(opt, spec)
		b.custom_minimum_size = BUTTON_MIN
		b.add_theme_font_size_override("font_size", 19)
		b.pressed.connect(_try_build.bind(opt))
		build_bar.add_child(b)

	# Instrumentation, last so the gameplay buttons come first. This is a test
	# build; on a phone the only way to report a frame rate is to put it on the
	# screen and let the tester photograph it.
	var perf := Button.new()
	perf.text = "PERF"
	perf.toggle_mode = true
	perf.custom_minimum_size = Vector2(110.0, BUTTON_MIN.y)
	perf.add_theme_font_size_override("font_size", 18)
	perf.toggled.connect(func(on):
		perf_panel.visible = on
		if on:
			_perf_readout())
	build_bar.add_child(perf)

	var qual := Button.new()
	qual.text = "QUALITY"
	qual.custom_minimum_size = Vector2(120.0, BUTTON_MIN.y)
	qual.add_theme_font_size_override("font_size", 18)
	qual.pressed.connect(_cycle_quality)
	build_bar.add_child(qual)

	# EFFECTS, one at a time. The frame budget has never been measured on the
	# phone, so "effects on/off" is a useless button — it says the lump costs
	# something and not which part. This walks them singly.
	var effects := Button.new()
	effects.custom_minimum_size = Vector2(130.0, BUTTON_MIN.y)
	effects.add_theme_font_size_override("font_size", 18)
	effects.pressed.connect(_cycle_effects)
	build_bar.add_child(effects)
	_fx_button = effects
	_refresh_fx_button()

	var lights := Button.new()
	lights.custom_minimum_size = Vector2(120.0, BUTTON_MIN.y)
	lights.add_theme_font_size_override("font_size", 18)
	lights.pressed.connect(_cycle_lights)
	build_bar.add_child(lights)
	_light_button = lights
	_refresh_light_button()

	# The way into the map editor from a phone. There is no other one: on
	# Android the project's main scene is whatever the editor was last told,
	# and changing it means going back to the project settings every time.
	var ed := Button.new()
	ed.text = "MAP\nEDITOR"
	ed.custom_minimum_size = Vector2(120.0, BUTTON_MIN.y)
	ed.add_theme_font_size_override("font_size", 18)
	ed.pressed.connect(func():
		get_tree().change_scene_to_file("res://scenes/editor/map_editor.tscn"))
	build_bar.add_child(ed)

	var stress := Button.new()
	stress.text = "TEST\nLOAD"
	stress.custom_minimum_size = Vector2(110.0, BUTTON_MIN.y)
	stress.add_theme_font_size_override("font_size", 18)
	stress.pressed.connect(_stress)
	build_bar.add_child(stress)


## Walk the effects one at a time so each can be priced on its own.
##
## all -> none -> flash+death -> shake -> wind -> ring -> all. "None" is in
## there as the baseline every other rung is measured against; without it the
## numbers are four readings with nothing to subtract from.
##
## The wind is the awkward one: it lives in a material the ModelLibrary
## mutates once, at spawn, so it cannot be toggled per frame like the others.
## The button sets it and says so, and it takes effect on the next scene load.
const FX_MODES := ["all", "none", "flash + death", "camera shake",
	"vine wind*", "emerge ring"]


func _cycle_effects() -> void:
	_fx_mode = (_fx_mode + 1) % FX_MODES.size()
	var only := func(which: String) -> bool:
		return _fx_mode == 0 or FX_MODES[_fx_mode] == which
	fx.hit_flash = only.call("flash + death")
	fx.death_fade = only.call("flash + death")
	fx.camera_shake = only.call("camera shake")
	fx.emerge_ring = only.call("emerge ring")
	fx.vine_wind = only.call("vine wind*")
	ModelLibrary.painted_sway_m = fx.sway_m if fx.vine_wind else 0.0
	probe.reset()
	_refresh_fx_button()
	_say("EFFECTS %s — timings restarted%s" % [FX_MODES[_fx_mode],
		". Wind changes on the next scene load."
		if FX_MODES[_fx_mode] == "vine wind*" or _fx_mode == 0 else ""])


func _refresh_fx_button() -> void:
	if _fx_button != null:
		_fx_button.text = "EFFECTS\n%s" % FX_MODES[_fx_mode]


## Cycle the two lighting experiments this machine cannot settle.
##
## THE POINT IS THE PROJECTOR. A SpotLight3D with anything in light_projector
## contributes exactly zero here — measured on Forward+ and Mobile alike, with
## an imported texture and a runtime one, while the same spot without a
## projector lights the scene fine. Godot's own feature list documents
## projector textures as a core feature with no renderer caveat, which makes
## software Vulkan (lavapipe) far and away the likeliest culprit — but the two
## cannot be told apart without a real GPU. One press on a phone settles it.
##
## The area fill is the other half: new in 4.7, Mobile runs it, and nobody has
## measured what it costs on an A54.
func _cycle_lights() -> void:
	_light_mode = (_light_mode + 1) % 4
	if _canopy_light != null:
		_canopy_light.visible = _light_mode == 1 or _light_mode == 3
	if _area_fill != null:
		_area_fill.visible = _light_mode == 2 or _light_mode == 3
	# The timings have to start over, or a minute on one setting and a minute
	# on another report one blended number describing neither.
	probe.reset()
	_refresh_light_button()
	_say("LIGHTS %s — timings restarted%s" % [_light_name(),
		"" if _canopy_light != null or _area_fill != null
		else " (neither light is built: check the palette and lighting .tres)"])


func _light_name() -> String:
	match _light_mode:
		0: return "base"
		1: return "canopy cookie"
		2: return "area fill"
		_: return "both"


func _refresh_light_button() -> void:
	if _light_button != null:
		_light_button.text = "LIGHTS\n%s" % _light_name()


## The reforge bar. Appears only when something is selected, because a bar of
## dead buttons is worse than no bar on a phone.
##
## Rebuilt on change rather than every frame: the signature is the selection
## plus the pooled mass, which is exactly what the offered list depends on.
func _refresh_forge_bar() -> void:
	# A selected machine can die, or be swallowed by a merge order. Drop it
	# from the selection rather than showing a pool that no longer exists.
	for k in range(selected.size() - 1, -1, -1):
		if _index_of(selected[k]) < 0:
			selected.remove_at(k)
	var sig := ",".join(selected.map(func(u): return str(u)))
	if sig == _forge_sig:
		return
	_forge_sig = sig
	for c in forge_bar.get_children():
		c.queue_free()
	forge_panel.visible = not selected.is_empty()
	if selected.is_empty():
		return

	var group := _selected_specs()
	var pool := MergePlanner.pool_mass(group)
	var head := Label.new()
	head.text = "%d selected\n%d mass" % [group.size(), int(pool)]
	head.add_theme_font_size_override("font_size", 19)
	head.add_theme_color_override("font_color", Color(1.0, 0.86, 0.35))
	head.custom_minimum_size = Vector2(120.0, BUTTON_MIN.y)
	head.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	forge_bar.add_child(head)

	var offers := forge_options()
	if offers.is_empty():
		var none := Label.new()
		none.text = "nothing this group\ncan become"
		none.add_theme_font_size_override("font_size", 18)
		none.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		forge_bar.add_child(none)
	for opt in offers:
		var spec := spec_for(opt)
		var b := Button.new()
		var spare := MergePlanner.leftover(pool, spec.mass)
		var note := "%.0fs" % MergePlanner.work_time(spec.mass, mass.cfg, forge)
		if spare > 0.0 and not MergePlanner.is_crumb(spare, forge):
			note += "  -%d" % int(spare)
		b.text = "→ %s\n%s  %s" % [opt.display_name, spec.role_name().left(4), note]
		b.tooltip_text = _machine_card(opt, spec)
		b.custom_minimum_size = BUTTON_MIN
		b.add_theme_font_size_override("font_size", 18)
		b.pressed.connect(_order_merge.bind(opt))
		forge_bar.add_child(b)

	var clear := Button.new()
	clear.text = "CLEAR"
	clear.custom_minimum_size = Vector2(110.0, BUTTON_MIN.y)
	clear.add_theme_font_size_override("font_size", 18)
	clear.pressed.connect(func(): selected.clear())
	forge_bar.add_child(clear)


## Switch quality preset and START THE MEASUREMENT OVER.
##
## The reset is the point. A session that ran three minutes on High and two on
## Low reports one blended p95 that describes neither, and the whole reason
## both presets exist is to find out what High actually costs on the device.
func _apply_quality(slot: int) -> void:
	_quality_slot = slot % QUALITY.size()
	quality = load(QUALITY[_quality_slot])
	QualityRig.apply(quality, get_viewport(), terrain, palette, ink)
	probe.reset()


func _cycle_quality() -> void:
	_apply_quality(_quality_slot + 1)
	_say("%s quality — frame timings restarted" % quality.display_name)


## The frame-time card. See FrameProbe for why the criteria are fixed in code
## rather than argued for after the first run on a device.
func _perf_readout() -> void:
	var lines := [
		"QUALITY  %s   (msaa %s, scale %.2f, detail %.1f)"
			% [quality.display_name, ["off", "2x", "4x", "8x"][quality.msaa_3d],
				quality.render_scale, quality.terrain_detail],
		"FPS  %.0f   (%.1f ms)" % [probe.live_fps(), probe.live_ms()],
		"p95  %.2f ms   mean %.2f" % [probe.session_p95(), probe.session_mean()],
		"worst minute  %.2f ms" % probe.worst_minute_ms(),
		"drift  x%.2f over %d min" % [probe.thermal_drift(), probe.minutes.size()],
		"",
		"draw %d   prims %.0fk   vram %.0f MB"
			% [probe.draw_calls, probe.primitives / 1000.0, probe.video_mb],
		"props %d of %d drawn   units %d   aliens %d"
			% [_scenery_drawn, _scenery_total, built.size(), aliens.size()],
		"soak %d:%02d" % [int(probe.elapsed) / 60, int(probe.elapsed) % 60],
		"",
	]
	var v := probe.verdict()
	if not v.ready:
		lines.append("VERDICT — %s" % v.note)
	else:
		lines.append("VERDICT: %s" % ("PASS" if v.pass else "FAIL"))
		for r in v.rows:
			lines.append("  %s  %-16s %s"
				% ["PASS" if r.pass else "FAIL", r.name, r.detail])
	perf_label.text = "\n".join(lines)


## Load the frame on purpose, so a worst case can be measured in a minute
## instead of waited for.
##
## This INJECTS MASS FROM NOWHERE, which the conservation rule forbids — that
## is why it says so on screen. It is instrumentation, not a game action, and
## it is the only thing in the build that breaks that rule.
func _stress() -> void:
	var heaviest: BuildOption = null
	for opt in options:
		if heaviest == null or spec_for(opt).mass > spec_for(heaviest).mass:
			heaviest = opt
	if heaviest == null:
		return
	var want := 12
	var cost := spec_for(heaviest).mass * want
	mass.gain(cost)
	for i in want:
		var a := TAU * i / float(want)
		_field(heaviest, spec_for(heaviest),
			module_pos + Vector2(cos(a), sin(a)) * (7.0 + _module_scale))
		mass.spend(spec_for(heaviest).mass)
	_spawn_hostiles(60, 3.0)
	fog.begin_frame()
	for i in 24:
		var a := TAU * i / 24.0
		fog.reveal(module_pos + Vector2(cos(a), sin(a)) * 34.0, 22.0)
	_scenery_dirty = true
	_say("TEST LOAD — %d machines, 60 hostiles, %d mass injected from nowhere"
		% [want, int(cost)])


# --- the loop ----------------------------------------------------------------
func _process(delta: float) -> void:
	step(delta)
	_present(delta)


## Simulation only — no meshes, no textures, no uploads.
##
## Split from presentation so the loop can be driven headlessly without a
## renderer. That is both the only way to test it and what CLAUDE.md means by a
## deterministic sim: presentation reads this state, it never writes it.
func step(delta: float) -> void:
	_walk_module(delta)
	_drone(delta)
	_assembly(delta)
	_merges(delta)
	_units(delta)
	_shots(delta)
	_hostiles(delta)
	waves.tick(delta)
	# The three sources the Hive owns. The debris dig is WaveDirector's, above.
	hive.tick(delta, module_pos, _alien_alive, _alien_pos)

	# Fog runs at 15 Hz, not 60. A pass touches a few thousand cells and
	# nothing about a reveal needs per-frame fidelity — a source would have to
	# cross a metre between frames for it to show.
	_fog_cd -= delta
	if _fog_cd <= 0.0:
		_fog_cd = 1.0 / FOG_HZ
		fog.begin_frame()
		fog.reveal(module_pos, tune.module_reveal_m)
		fog.reveal(drone_pos, tune.drone_reveal_m)
		for u in built:
			if u.spec.reveal_m > 0.0:
				fog.reveal(u.pos, u.spec.reveal_m)
		_scenery_dirty = true


## The drone is the only thing that moves mass. Everything else spends it.
func _drone(delta: float) -> void:
	match drone_state:
		"idle":
			# IT WAITS. The drone used to fly to the nearest piece the moment
			# it had nothing to do, which meant the mass economy ran itself and
			# the player watched it happen. Collecting is an ORDER now: tap a
			# piece. What the drone does unasked is keep station on the module.
			if tune.drone_auto_collect:
				var next := _nearest_job()
				if next >= 0:
					drone_target = next
					drone_state = "outbound"
					return
			_fly_toward(module_pos, delta)
		"outbound":
			var t: Variant = _job_pos(drone_target)
			if t == null:
				_abort_job()
			elif _fly_toward(t as Vector2, delta):
				drone_state = "working"
				free_progress = 0.0
				if _is_large_job(drone_target):
					waves.begin(&"large_debris", 1.0 + debris.size() * 0.05)
		"working":
			var job := _job(drone_target)
			if job.is_empty():
				_abort_job()
				return
			# Small pieces and wrecks lift straight away; stuck ones take work,
			# and that work is what the hive notices.
			var need: float = tune.large_free_s if _is_large_job(drone_target) \
				else tune.small_free_s
			free_progress += delta
			if free_progress >= need:
				drone_cargo = job.mass
				drone_cargo_is_wreck = job.get("wreck", false)
				_consume_job(drone_target)
				drone_target = -1
				drone_state = "returning"
				waves.end()
		"returning":
			if _fly_toward(module_pos, delta):
				var got := mass.recover(drone_cargo) if drone_cargo_is_wreck \
					else mass.gain(drone_cargo)
				_say("+%.0f mass" % got)
				drone_cargo = 0.0
				drone_state = "idle"


func _fly_toward(target: Vector2, delta: float) -> bool:
	var to := target - drone_pos
	var d := to.length()
	if d < 0.6:
		return true
	drone_pos += to / d * minf(tune.drone_speed_mps * delta, d)
	return false


## The job nearest a tap, of any kind — wreck, small debris or a stuck piece.
##
## Wrecks win a tie. They are worth more than the debris beside them and the
## player almost certainly meant the thing they just lost, not the scenery it
## fell on.
func _job_near(p: Vector2, reach: float) -> int:
	var best := -1
	var bd := reach
	for i in debris.size():
		if debris[i].taken:
			continue
		var d: float = (debris[i].pos as Vector2).distance_to(p)
		if d < bd:
			bd = d
			best = i
	for i in wrecks.size():
		var d: float = (wrecks[i].pos as Vector2).distance_to(p)
		if d <= bd:
			bd = d
			best = 1000 + i
	return best


## Wrecks first — recovering your own losses should never queue behind
## exploring, or a bad fight compounds itself.
##
## UNUSED while drone_auto_collect is false, which is the shipped setting. Kept
## rather than deleted so the old hands-off economy can be switched back on and
## measured against the new one.
func _nearest_job() -> int:
	var best := -1
	var bd := 1e9
	for i in wrecks.size():
		var wp: Vector2 = wrecks[i].pos
		var d := wp.distance_to(drone_pos)
		if d < bd:
			bd = d
			best = 1000 + i
	if best >= 0:
		return best
	for i in debris.size():
		if debris[i].taken or debris[i].large:
			continue
		var dp: Vector2 = debris[i].pos
		var d := dp.distance_to(drone_pos)
		if d < bd:
			bd = d
			best = i
	return best


func _is_large_job(id: int) -> bool:
	return id >= 0 and id < 1000 and debris[id].large


func _job(id: int) -> Dictionary:
	if id < 0:
		return {}
	if id >= 1000:
		var i := id - 1000
		return wrecks[i] if i < wrecks.size() else {}
	return debris[id] if id < debris.size() and not debris[id].taken else {}


func _job_pos(id: int) -> Variant:
	var j := _job(id)
	return null if j.is_empty() else j.pos


func _consume_job(id: int) -> void:
	if id >= 1000:
		wrecks.remove_at(id - 1000)
	else:
		debris[id].taken = true


func _abort_job() -> void:
	drone_target = -1
	drone_state = "idle"
	waves.end()


## Dig where the player drags. The only thing in the game that stays where it
## was put — and it costs no mass at all.
##
## Mass is the module's body relocated into units and structures; it is never
## consumed, only moved. Earth is not body, so shifting earth spends nothing.
## What a trench costs is time the drone is not collecting, and the fact that
## the convoy moves on and leaves it behind.
func _dig(at: Vector2, delta: float) -> void:
	field.deform(at, tune.trench_radius_m, tune.trench_rate_per_s * delta)
	terrain.mark_dirty()


## Committing mass to a machine. The mass leaves the module's body the instant
## the player presses the button — that is why it shrinks straight away — but
## the machine takes `build_time_for(mass)` seconds to exist — heavier
## machines take longer, so the size of a thing means something.
##
## That delay is the whole cost of the economy. Mass is conserved, so scrapping
## and rebuilding loses nothing; what it costs is these seconds, plus the drone
## trip to fetch the wreck first. A player who churns their army every wave is
## not poorer, they are late.
func _try_build(opt: BuildOption) -> void:
	var spec := spec_for(opt)
	if not spec.is_valid():
		_say("%s will not assemble: %s" % [opt.display_name, spec.errors[0]])
		return
	if not mass.spend(spec.mass):
		return
	var a := _rng.randf() * TAU
	var p := module_pos + Vector2(cos(a), sin(a)) * (3.0 + _module_scale)
	var secs := mass.cfg.build_time_for(spec.mass)
	assembling.append({"opt": opt, "spec": spec, "pos": p, "left": secs, "total": secs})
	_say("%s — %d mass committed, %.0fs to assemble"
		% [opt.display_name, int(spec.mass), secs])


## Machines finish assembling and join the convoy.
func _assembly(delta: float) -> void:
	for i in range(assembling.size() - 1, -1, -1):
		var job := assembling[i]
		job.left -= delta
		if job.left > 0.0:
			continue
		var spec: MachineSpec = job.spec
		var cds := PackedFloat32Array()
		cds.resize(spec.weapons.size())
		_field(job.opt, spec, job.pos)
		assembling.remove_at(i)
		_say("%s ready" % spec.display_name)


## Put a finished machine on the field. One place, so a machine that arrived
## from the build queue and one that came out of a merge are identical.
func _field(opt: BuildOption, spec: MachineSpec, at: Vector2) -> Dictionary:
	var cds := PackedFloat32Array()
	cds.resize(spec.weapons.size())
	var u := {
		"uid": _next_uid, "opt": opt, "spec": spec, "pos": at, "hp": spec.max_hp,
		"cd": 0.0, "cds": cds, "slot": built.size(), "rally": null,
	}
	_next_uid += 1
	built.append(u)
	return u


func _index_of(uid: int) -> int:
	for i in built.size():
		if built[i].uid == uid:
			return i
	return -1


## Scrap a live machine back into the module.
##
## Lossless in mass and expensive in time: the machine becomes a wreck where it
## stands, so the drone has to fly out and haul it home before that mass is
## usable, and whatever the player builds instead takes its own assembly time
## that. Repurposing is always available and never free.
func _scrap(index: int) -> void:
	if index < 0 or index >= built.size():
		return
	var u := built[index]
	wrecks.append({"pos": u.pos, "mass": u.spec.mass, "wreck": true})
	built.remove_at(index)
	_say("%s scrapped — the drone has to fetch it" % u.spec.display_name)


# --- reforging in the field --------------------------------------------------
## What the current selection could become, heaviest first.
##
## A machine is mass in a shape. One Skirmisher can become anything up to its
## own 14 mass; two of them pool 28 and can become a Lancer or a Breaker. That
## is the whole rule — if you want something bigger, bring more machines.
func forge_options() -> Array:
	var group := _selected_specs()
	if group.is_empty() or not MergePlanner.group_is_legal(group.size(), forge):
		return []
	var only: StringName = &""
	if group.size() == 1:
		only = (group[0] as MachineSpec).id
	return MergePlanner.candidates(MergePlanner.pool_mass(group), options, specs, only)


func _selected_specs() -> Array:
	var out: Array = []
	for uid in selected:
		var i := _index_of(uid)
		if i >= 0:
			out.append(built[i].spec)
	return out


## Order the selection to become `target`. They walk together first.
func _order_merge(target: BuildOption) -> void:
	var group := _selected_specs()
	if group.is_empty():
		return
	if not MergePlanner.group_is_legal(group.size(), forge):
		_say("too many at once — %d machines is the most that can combine" % forge.max_group)
		return
	var pool := MergePlanner.pool_mass(group)
	var want := spec_for(target)
	if want.mass > pool + 0.001:
		_say("%s needs %d mass — this group is %d. Add another machine."
			% [target.display_name, int(want.mass), int(pool)])
		return

	# Rendezvous at the group's centre of mass, so nobody walks further than
	# they must and the merge happens where the player was already looking.
	var at := Vector2.ZERO
	var uids: Array[int] = []
	for uid in selected:
		var i := _index_of(uid)
		if i < 0:
			continue
		at += built[i].pos
		uids.append(uid)
		built[i].rally = Vector2.ZERO        # filled in below once `at` is known
	if uids.is_empty():
		return
	at /= float(uids.size())
	for uid in uids:
		built[_index_of(uid)].rally = at

	merging.append({
		"uids": uids, "opt": target, "spec": want, "at": at,
		"state": "gathering", "left": 0.0, "wait": 0.0,
	})
	selected.clear()
	if uids.size() == 1:
		_say("%s is reshaping into a %s" % [group[0].display_name, target.display_name])
	else:
		_say("%d machines converging to form a %s" % [uids.size(), target.display_name])


func _merges(delta: float) -> void:
	for i in range(merging.size() - 1, -1, -1):
		var job := merging[i]
		if job.state == "gathering":
			if _gather(job, delta):
				merging.remove_at(i)
		else:
			job.left -= delta
			if job.left <= 0.0:
				_finish_merge(job)
				merging.remove_at(i)


## Wait for every member to reach the rendezvous, then start the work.
##
## Members can die on the way. That does not cancel the order — it shrinks the
## pool, and if the pool can no longer make the target the order downgrades to
## the best thing the survivors can still become. Losing a machine mid-merge
## should cost you the machine, not the whole decision.
## Returns true when the order is finished with — abandoned or started.
func _gather(job: Dictionary, delta: float) -> bool:
	job.wait += delta
	var alive: Array[int] = []
	var pool := 0.0
	var here := 0
	for uid in job.uids:
		var i := _index_of(uid)
		if i < 0:
			continue
		alive.append(uid)
		pool += built[i].spec.mass
		if built[i].pos.distance_to(job.at) <= forge.gather_radius_m:
			here += 1
	job.uids = alive

	if alive.is_empty():
		return true

	if pool + 0.001 < job.spec.mass:
		var fallback := MergePlanner.best(pool, options, specs)
		if fallback == null:
			_release(job)
			_say("the merge lost too much — the survivors go back to formation")
			return true
		job.opt = fallback
		job.spec = spec_for(fallback)
		_say("down to %d mass — reforging as a %s instead" % [int(pool), fallback.display_name])

	if here < alive.size():
		if job.wait < forge.gather_timeout_s:
			return false
		_release(job)
		_say("they could not reach each other — merge abandoned")
		return true

	# Everyone has arrived. The machines come apart here and the new one starts
	# assembling; from this moment the group is off the board.
	for uid in alive:
		var i := _index_of(uid)
		if i >= 0:
			built.remove_at(i)
	job.state = "working"
	job.left = MergePlanner.work_time(job.spec.mass, mass.cfg, forge)
	job.total = job.left
	job.pool = pool
	return false


func _finish_merge(job: Dictionary) -> void:
	_field(job.opt, job.spec, job.at)
	# Mass the new shape could not use. NOTHING is destroyed here — the rule is
	# conservation, so every gram either lies on the ground as an offcut the
	# drone must fetch (which is what makes overshooting a merge cost a trip)
	# or, if it is too small to be worth a trip, goes straight home.
	var spare := MergePlanner.leftover(job.pool, job.spec.mass)
	if spare <= 0.0:
		_say("%s forged" % job.spec.display_name)
	elif MergePlanner.is_crumb(spare, forge) or not forge.leftover_as_wreck:
		mass.gain(spare)
		_say("%s forged" % job.spec.display_name)
	else:
		wrecks.append({"pos": job.at + Vector2(1.2, 0.8), "mass": spare, "wreck": true})
		_say("%s forged — %d mass of offcuts left for the drone"
			% [job.spec.display_name, int(spare)])


## Every gram in the world, wherever it currently happens to be.
##
## Mass is conserved, so this number only moves when the drone brings something
## in from outside the loop — or when hostiles chew on the module, which is the
## one place in the game that genuinely destroys body. Everything else here
## just shuffles mass between buckets, and this is how that gets checked rather
## than asserted in a comment.
func system_mass() -> float:
	var total := mass.mass + drone_cargo
	for u in built:
		total += u.spec.mass
	for job in assembling:
		total += job.spec.mass           # committed, not yet standing
	for job in merging:
		if job.state == "working":
			total += job.pool            # gathering groups are still in `built`
	for w in wrecks:
		total += w.mass
	for d in debris:
		if not d.taken:
			total += d.mass
	return total


## Send an abandoned group back to formation.
func _release(job: Dictionary) -> void:
	for uid in job.uids:
		var i := _index_of(uid)
		if i >= 0:
			built[i].rally = null


## One machine's numbers as the player needs to compare them. Range and dead
## zone matter more than damage here: an artillery piece with a twelve-metre
## hole is a different decision from a brawler, at similar mass.
func _machine_card(opt: BuildOption, spec: MachineSpec) -> String:
	var lines := [
		"%s — %s" % [spec.display_name, spec.role_name()],
		"%.0f mass   %.0f hp   %.0f armour" % [spec.mass, spec.max_hp, spec.armour],
		"%.1f dps   %.1f m/s" % [spec.dps(), spec.speed_mps],
	]
	if spec.max_range_m() > 0.0:
		var hole := spec.min_engage_m()
		lines.append("reach %.0f m%s" % [spec.max_range_m(),
			"   blind inside %.0f m" % hole if hole > 0.0 else ""])
	if spec.reveal_m > 0.0:
		lines.append("sees %.0f m" % spec.reveal_m)
	if spec.overloaded:
		lines.append("OVERLOADED — moves at %.0f%% speed" % (spec.speed_penalty * 100.0))
	if opt.description != "":
		lines.append("")
		lines.append(opt.description)
	return "\n".join(lines)


## EVERYTHING the module builds travels with it. Nothing roots down.
##
## That resolves the caravan-versus-emplacement tension in docs/loop-v2.md in
## favour of the caravan: the only permanent thing the player can place is a
## dug trench, which makes terrain the whole of their static defence and gives
## deformable ground a job no building can take.
##
## Stations are a ring around the module, evenly spaced by slot so the convoy
## reads as a formation rather than a clump, at a per-option radius so heavy
## things meet trouble first.
func _units(delta: float) -> void:
	for i in range(built.size() - 1, -1, -1):
		var u := built[i]
		u.cd -= delta
		u.flash = maxf(0.0, float(u.get("flash", 0.0)) - delta)
		var upos: Vector2 = u.pos
		# A machine under a merge order leaves formation and walks to the
		# rendezvous. That hole in the line is half the cost of reforging.
		var rallying: bool = u.rally != null
		var station: Vector2 = u.rally if rallying else _station(i, built.size(), u.opt)
		var gap := station - upos
		var dist := gap.length()
		if dist > 0.05:
			# A spring, not a leash: something left behind closes faster, so
			# the convoy regroups instead of stringing out across the map.
			var urgency := 1.0 + (dist / maxf(1.0, tune.escort_radius_m)) * tune.escort_catchup
			if rallying:
				urgency = forge.gather_speed_mult
			var speed: float = u.spec.escort_speed_mps * urgency
			u.pos = upos + gap / dist * minf(speed * delta, dist)
		_fire(u, delta)
		if u.hp <= 0.0:
			# Not deleted — it becomes a wreck the drone can recover. Every
			# gram comes back: what the player lost is the machine's time.
			wrecks.append({"pos": u.pos, "mass": u.spec.mass, "wreck": true})
			built.remove_at(i)
			_say("%s lost — wreck marked for recovery" % u.spec.display_name)


## Every weapon fitted to a machine fires on its own cooldown.
##
## This is where a loadout stops being a spreadsheet. A melee arm and a mortar
## on the same frame genuinely cover different bands, because each weapon picks
## its own target inside its own range — and an artillery piece simply finds no
## target inside its minimum range, which is the hole its escort exists to fill.
func _fire(u: Dictionary, delta: float) -> void:
	var spec: MachineSpec = u.spec
	var cds: PackedFloat32Array = u.cds
	for w in spec.weapons.size():
		cds[w] = maxf(0.0, cds[w] - delta)
		if cds[w] > 0.0:
			continue
		var gun: Dictionary = spec.weapons[w]
		var t := _nearest_alien_in_band(u.pos, gun.min_range_m, gun.range_m)
		if t < 0:
			continue
		cds[w] = gun.cooldown_s
		_launch(u.pos, t, gun)


## Put one shot in the air, or land it immediately if the weapon is a claw.
##
## MELEE DOES NOT GET A PROJECTILE. A flight time on a contact weapon means a
## swing that connects with something that has already walked away, which is
## not a tradeoff, just a bug with a reason attached.
func _launch(from: Vector2, target_index: int, gun: Dictionary) -> void:
	var a: Dictionary = aliens[target_index]
	var speed := _shot_speed(gun.family)
	if speed <= 0.0:
		_land(a.pos, int(a.uid), gun.damage, gun.splash_m)
		return
	if shots.size() >= tune.shot_cap:
		# Over the cap the shot still HITS, it just is not drawn travelling.
		# Dropping the damage instead would make a big fight quietly weaker
		# than a small one, which is the sort of thing nobody finds for months.
		_land(a.pos, int(a.uid), gun.damage, gun.splash_m)
		return
	var aim: Vector2 = a.pos
	shots.append({
		"pos": from, "from": from, "aim": aim, "target": int(a.uid),
		"damage": gun.damage, "splash_m": gun.splash_m, "speed": speed,
		"family": gun.family, "flown": 0.0,
		"span": maxf(0.01, from.distance_to(aim)),
	})


func _shot_speed(family: int) -> float:
	match family:
		MachinePart.Family.RANGED:
			return tune.shot_speed_ranged_mps
		MachinePart.Family.ARTILLERY:
			return tune.shot_speed_artillery_mps
		_:
			return 0.0


## Fly every shot, and resolve the ones that arrive.
##
## A shot re-aims at its target while the target lives, so a bolt tracks a
## running swarmer instead of landing where it used to be. When the target dies
## in flight the shot keeps going to the last place it was aimed: a shell still
## lands and still splashes, and a direct-fire bolt simply misses. That miss is
## the price of the travel time being real, and it is why artillery is worth
## its minimum range.
func _shots(delta: float) -> void:
	for i in range(shots.size() - 1, -1, -1):
		var sh: Dictionary = shots[i]
		var live := _alien_index(int(sh.target))
		if live >= 0:
			sh.aim = aliens[live].pos
		var to: Vector2 = sh.aim - sh.pos
		var d := to.length()
		var step: float = sh.speed * delta
		if d > step and d > 0.001:
			sh.pos = (sh.pos as Vector2) + to / d * step
			sh.flown = float(sh.flown) + step
			continue
		shots.remove_at(i)
		_land(sh.aim, int(sh.target) if live >= 0 else -1,
			sh.damage, sh.splash_m)


## Apply a shot where it came down. `direct` is the id it was aimed at, or -1
## if that thing died on the way — a direct hit needs something to hit, splash
## does not care.
func _land(at: Vector2, direct: int, damage: float, splash_m: float) -> void:
	if direct >= 0:
		var i := _alien_index(direct)
		if i >= 0 and float(aliens[i].get("dying", ALIVE)) < 0.0:
			aliens[i].hp -= damage
			_hurt(i)
	if splash_m <= 0.0:
		if not fx.shake_splash_only:
			_kick(at, damage)
		return
	# Splash lands: this is the one that gets weight. Scaled by the radius as
	# well as the damage, because a big shell should feel bigger than a hard
	# one.
	_kick(at, damage * (1.0 + splash_m * 0.25))
	# Splash is what an artillery shell is FOR. Full damage at the centre,
	# nothing at the rim, so a tight swarm is punished and a spread one is not
	# — which is the behaviour that makes spacing matter to the enemy.
	for j in aliens.size():
		if int(aliens[j].uid) == direct:
			continue
		if float(aliens[j].get("dying", ALIVE)) >= 0.0:
			continue
		var d: float = at.distance_to(aliens[j].pos)
		if d < splash_m:
			aliens[j].hp -= damage * (1.0 - d / splash_m)
			_hurt(j)


## Light something up for a moment. The whole of the hit-flash effect: one
## float on a record that is already being written every frame.
func _hurt(i: int) -> void:
	if fx.hit_flash and i >= 0 and i < aliens.size():
		aliens[i].flash = fx.flash_s


## Kick the camera.
##
## `at` is where it happened and `damage` is how hard. Falls off with distance
## from the VIEW CENTRE rather than from the module, because the question is
## "did the player see this", and a player who has panned away should not be
## shaken by something off screen.
##
## It costs nothing to draw, which is why it is the best value in the effects
## list — and it is the easiest to overdo, which is why every number in it is
## in EffectsConfig.
func _kick(at: Vector2, damage: float) -> void:
	if not fx.camera_shake:
		return
	var centre := Vector2(rig.position.x, rig.position.z)
	var d := at.distance_to(centre)
	if d > fx.shake_range_m:
		return
	var fall := 1.0 - d / maxf(1.0, fx.shake_range_m)
	# maxf, not +=. Shakes do not stack: twelve machines firing at once would
	# otherwise add up to a camera leaving the building.
	_shake = minf(fx.shake_max_m,
		maxf(_shake, damage * fx.shake_per_damage * fall))


func _alien_index(uid: int) -> int:
	for i in aliens.size():
		if int(aliens[i].uid) == uid:
			return i
	return -1


## Evenly spaced ring position for one convoy member.
func _station(slot: int, total: int, opt: BuildOption) -> Vector2:
	var r: float = opt.escort_radius_m if opt.escort_radius_m > 0.0 else tune.escort_radius_m
	var a := TAU * (float(slot) / maxf(1.0, float(total)))
	return module_pos + Vector2(cos(a), sin(a)) * (r + _module_scale)


## Nearest hostile between two ranges. `min_r` is what makes artillery
## artillery: a mortar with a seven-metre minimum simply cannot see the thing
## chewing on its legs, and no amount of damage on the sheet changes that.
func _nearest_alien_in_band(from: Vector2, min_r: float, max_r: float) -> int:
	if max_r <= 0.0:
		return -1
	var best := -1
	var bd := max_r
	for i in aliens.size():
		# A CORPSE IS NOT A TARGET. Without this the convoy keeps firing at
		# something that is already falling over, and the third of a second a
		# death takes becomes a third of a second of everyone's damage thrown
		# away — an effect that quietly made the game harder.
		if float(aliens[i].get("dying", ALIVE)) >= 0.0:
			continue
		var d: float = aliens[i].pos.distance_to(from)
		if d < min_r or d >= bd:
			continue
		bd = d
		best = i
	return best


func _nearest_alien(from: Vector2, rng: float) -> int:
	var best := -1
	var bd := rng
	for i in aliens.size():
		if float(aliens[i].get("dying", ALIVE)) >= 0.0:
			continue          # do not aim a turret at a falling corpse
		var ap: Vector2 = aliens[i].pos
		var d := ap.distance_to(from)
		if d < bd:
			bd = d
			best = i
	return best


## One alien, of whatever kind, at a place. Every source goes through here so
## that ids, emerge timers and the record's shape are decided once.
##
## `emerge` is why an alien does not simply appear: for its first second and a
## half it is climbing out and cannot move. An alien that arrives at full speed
## reads as spawned; one that heaves itself out of the ground reads as having
## been there all along, and it gives the player a beat to react.
func _add_alien(at: Vector2, hp: float, kind: StringName,
		emerge := -1.0) -> int:
	var cfg := field.cfg
	var uid := _next_alien_uid
	_next_alien_uid += 1
	aliens.append({
		"uid": uid,
		"pos": Vector2(clampf(at.x, 2.0, cfg.cells_x - 2.0),
			clampf(at.y, 2.0, cfg.cells_z - 2.0)),
		# hp_max is recorded at birth. A health bar needs a denominator, and a
		# roamer, a nest and a swarmer are all "an alien" with wildly different
		# ones — reading it back off the config at draw time would need the
		# kind-to-config mapping in two places.
		"hp": hp, "hp_max": maxf(1.0, hp), "cd": 0.0, "kind": kind,
		# Seconds of hit flash left, and seconds of dying left. ALIVE is the
		# sentinel, not zero: a corpse counts DOWN to zero and is removed at
		# it, so "dying == 0" has to mean "gone this frame", which makes zero
		# the worst possible value for "has not started". Initialising it to
		# 0.0 made every living alien test as a corpse, and nothing on the map
		# could be shot at all.
		"flash": 0.0, "dying": ALIVE,
		"emerge": hive_cfg.emerge_s if emerge < 0.0 else emerge,
	})
	return uid


func _alien_alive(uid: int) -> bool:
	for a in aliens:
		if int(a.uid) == uid:
			return float(a.hp) > 0.0
	return false


## Which roamer an id belongs to, or -1. Two of them, so a scan is the whole
## implementation.
func _roamer_slot(uid: int) -> int:
	for i in hive.roamers.size():
		if int(hive.roamers[i].alien) == uid:
			return i
	return -1


func _alien_pos(uid: int) -> Vector2:
	for a in aliens:
		if int(a.uid) == uid:
			return a.pos
	return Vector2.ZERO


## THE DEBRIS WAVE, and it comes up through the ground like everything else.
##
## It used to walk in from a ring 46-60 m out, which is the one source that did
## not match the rest: the hive is underground, so an alarm should bring it up
## near the thing that raised it. Burrow patches within reach of the module are
## used first; the old ring is the fallback for a module standing somewhere
## with nothing buried nearby.
## Put the hive on the map, and give its roamers and nests bodies.
##
## A roamer and a nest are ALIENS, not a separate kind of thing: one flat array
## with a `kind` on each record means targeting, splash, damage, the death
## sweep and the renderer all already handle them. A parallel list would need
## every one of those again and would drift from it within a week.
func _populate_hive(landing: Vector2) -> void:
	var made := hive.place(_plant_spots, landing, tune.module_reveal_m)
	for i in (made.roamers as Array).size():
		var at: Vector2 = made.roamers[i]
		hive.bind_roamer(i, _add_alien(at, hive_cfg.roamer_hp, &"roamer", 0.0))
	for i in (made.plants as Array).size():
		var at: Vector2 = made.plants[i]
		hive.bind_plant(i, _add_alien(at, hive_cfg.plant_hp, &"nest", 0.0))
	print("hive: %d roaming, %d plant nests, %d buried patches"
		% [hive.roamers.size(), hive.plants.size(), hive.patches.size()])


## A source called something up. Every brood in the game comes through here.
func _brood(at: Vector2, count: int, source: StringName) -> void:
	var radius := hive_cfg.patch_brood_radius_m
	if source == &"roamer":
		radius = hive_cfg.roamer_brood_radius_m
	elif source == &"plant":
		radius = hive_cfg.plant_brood_radius_m
	for i in count:
		_add_alien(hive.emerge_point(at, radius), waves.hostile_hp(), &"small")


func _hive_woke(source: StringName, _at: Vector2) -> void:
	if source == &"plant":
		_say("SOMETHING IN THE PLANT — kill it or it keeps calling")
	elif source == &"patch":
		_say("THE GROUND OPENED — they were already here")


func _spawn_hostiles(count: int, intensity: float) -> void:
	var near: Array[Vector2] = []
	for q in hive.patches:
		var at: Vector2 = q.pos
		if at.distance_to(module_pos) <= hive_cfg.burrow_reach_m:
			near.append(at)
	for i in count:
		var p: Vector2
		if near.is_empty():
			var a := _rng.randf() * TAU
			p = module_pos + Vector2(cos(a), sin(a)) * lerpf(
				tune.spawn_ring_m.x, tune.spawn_ring_m.y, _rng.randf())
		else:
			p = hive.emerge_point(near[_rng.randi() % near.size()], 4.0)
		_add_alien(p, waves.hostile_hp(), &"small")


## Drive the module toward where the player tapped.
##
## Slides along a blocked edge rather than stopping dead, the same rule the
## aliens use: a body that halts the moment its straight line is blocked reads
## as broken, and the map is full of rims that clip a straight line by half a
## metre.
func _walk_module(delta: float) -> void:
	var to := module_goal - module_pos
	var d := to.length()
	if d <= tune.module_arrive_m:
		return
	var step := to / d * minf(tune.module_speed_mps * delta, d)
	var next := module_pos + step
	if field.is_passable(next):
		module_pos = next
	else:
		var side := Vector2(-to.y, to.x).normalized() * tune.module_speed_mps * delta
		if field.is_passable(module_pos + side):
			module_pos += side
		elif field.is_passable(module_pos - side):
			module_pos -= side
		else:
			module_goal = module_pos      # boxed in; stop asking
	# NO CAMERA HERE. This used to set rig.position, which is the CAMERA pivot,
	# not the module — the module's mesh is placed in _present. Two things were
	# wrong with it: step() is documented sim-only and a camera is presentation,
	# and re-centring every frame the module moved meant a pan was wiped out on
	# the next step, so the player could not look anywhere while walking.
	# _follow_module does it instead, on a leash.


func _hostiles(delta: float) -> void:
	for i in range(aliens.size() - 1, -1, -1):
		var al := aliens[i]
		al.flash = maxf(0.0, float(al.get("flash", 0.0)) - delta)
		if al.hp <= 0.0:
			# DYING IS A STATE, not an instant. Things used to vanish
			# mid-stride, which reads as a rendering glitch rather than a kill.
			#
			# A corpse is NOT a threat and not a target: _nearest_alien_in_band
			# skips it, _land cannot damage it, it does not bite, the Hive's
			# `alive` callback already reports it dead the moment hp hits zero,
			# and the HOSTILES tally leaves it out. A corpse that still soaks
			# bullets is worse than no effect at all.
			if not fx.death_fade:
				aliens.remove_at(i)
				continue
			var left := float(al.get("dying", ALIVE))
			if left < 0.0:
				al.dying = fx.death_s
			elif left <= 0.0:
				aliens.remove_at(i)
			else:
				# CLAMPED AT ZERO, and that is not tidiness. `dying < 0` is the
				# sentinel for "has not started", so a countdown allowed to go
				# negative reads as "has not started" on the very next frame
				# and sets itself back to death_s — a corpse that resets its
				# own timer, forever, and never leaves the map.
				al.dying = maxf(0.0, left - delta)
			continue
		# CLIMBING OUT. Not movable, not yet a threat, and visibly arriving.
		if float(al.get("emerge", 0.0)) > 0.0:
			al.emerge = float(al.emerge) - delta
			continue
		al.cd -= delta
		var apos: Vector2 = al.pos
		var kind: StringName = al.get("kind", &"small")
		# A NEST DOES NOT MOVE AND DOES NOT BITE. It is a plant with hit points
		# standing where the dressing already put one; its whole threat is what
		# it calls up, which is why killing it is the off switch.
		if kind == &"nest":
			continue
		# A ROAMER HAS TERRITORY, not a target. It walks its own ground and
		# the escorts are the threat; chasing the player across the map would
		# make two large creatures into two pursuers, which is a different and
		# much worse encounter.
		if kind == &"roamer":
			var goal := hive.roamer_goal(_roamer_slot(int(al.uid)), apos)
			var away := goal - apos
			var dist := away.length()
			if dist > 0.5:
				var nxt := apos + away / dist * tune.alien_speed_mps * 0.45 * delta
				if field.is_passable(nxt):
					al.pos = nxt
			continue
		var target := module_pos
		var best := apos.distance_to(module_pos)
		for u in built:
			var upos2: Vector2 = u.pos
			var d := apos.distance_to(upos2)
			if d < best:
				best = d
				target = u.pos
		var to := target - apos
		var d2 := to.length()
		if d2 > 1.4:
			# Terrain still matters: a trench or chasm stops them.
			var step := to / d2 * tune.alien_speed_mps * delta
			var next := apos + step
			if field.is_passable(next):
				al.pos = next
			else:
				var side := Vector2(-to.y, to.x).normalized() * tune.alien_speed_mps * delta
				if field.is_passable(apos + side):
					al.pos = apos + side
		elif al.cd <= 0.0:
			al.cd = tune.alien_attack_cd_s
			var hit := false
			for u in built:
				var up: Vector2 = u.pos
				if apos.distance_to(up) <= 1.6:
					# Plating is the only reason a Breaker can stand in a swarm
					# that kills a Skirmisher. Reduction, not hit points, so
					# armour is worth more the smaller each bite is.
					u.hp -= u.spec.damage_after_armour(tune.alien_damage, rules)
					u.flash = fx.flash_s if fx.hit_flash else 0.0
					hit = true
					break
			if not hit:
				# Chewing on the module costs body — that is the whole point of
				# mass — but slowly enough that the player can answer it. The
				# first pass drained 1.75 mass/second per hostile and ate a
				# 36-mass module in under three seconds, which is not a fight.
				var bite := tune.module_drain_per_s * tune.alien_attack_cd_s
				mass.mass = maxf(0.0, mass.mass - bite)
				mass.changed.emit(mass.mass, -bite)
				_module_flash = fx.flash_s if fx.hit_flash else 0.0


# --- presentation ------------------------------------------------------------
func _present(delta: float) -> void:
	# The module IS the mass readout. Ease toward the target so spending reads
	# as a visible shrink rather than a pop.
	var want := mass.display_scale()
	_module_scale = lerpf(_module_scale, want,
		clampf(delta / maxf(0.01, mass.cfg.scale_tween_s), 0.0, 1.0))
	module.scale = Vector3.ONE * _module_scale
	_set_module_form(_form_for_mass())
	_module_flash = maxf(0.0, _module_flash - delta)
	_flash_node(module, _module_flash, fx.flash_friendly)
	module.position = Vector3(module_pos.x, terrain.height_at(module_pos), module_pos.y)
	_ease_zoom(delta)
	# Decay the shake and re-aim, but ONLY while there is one. A quiet frame
	# does not touch the camera at all, which is what makes this effect free.
	if _shake > 0.0001:
		_shake_t += delta
		_shake = maxf(0.0, _shake - _shake * fx.shake_decay * delta
			- 0.02 * delta)
		_frame_camera()
	elif _shake != 0.0:
		_shake = 0.0
		_frame_camera()          # one last call, to put it exactly back
	_follow_module(delta)
	drone.position = Vector3(drone_pos.x, terrain.height_at(drone_pos) + 5.5, drone_pos.y)
	for r in drone.find_children("rotor_*", "Node3D", true, false):
		(r as Node3D).rotate_y(delta * 26.0)

	_draw(_mm_debris, debris.filter(func(d): return not d.taken),
		func(d): return Vector3(0.9, 0.9, 0.9) * (2.3 if d.large else 1.0),
		func(d): return Color(1.0, 0.62, 0.28) if d.large else Color(0.85, 0.74, 0.42))
	_sync_convoy()
	_sync_aliens()
	_draw(_mm_aliens, aliens.slice(mini(aliens.size(), tune.animated_alien_cap)),
		_alien_size, _alien_tint)
	# Scenery is static, so it only needs resubmitting when the fog moved.
	if _scenery_dirty:
		_scenery_dirty = false
		_cull_scenery()
	_draw(_mm_marks, _markers(),
		func(m): return Vector3(m.r, 0.12, m.r),
		func(m): return m.col)
	_draw_shots()
	_draw_bars()
	_refresh_forge_bar()

	terrain.upload()
	fog.upload(delta)
	probe.sample(delta)
	_hud(delta)
	if perf_panel.visible:
		_perf_readout()


## Discs on the ground: amber under a selected machine, cyan at a rendezvous a
## merge is converging on. The rendezvous ring is drawn at the gather radius, so
## the player can see exactly how close the group has to get.
func _markers() -> Array:
	var out: Array = []
	for uid in selected:
		var i := _index_of(uid)
		if i >= 0:
			out.append({"pos": built[i].pos, "r": built[i].spec.radius_m * 2.6,
				"col": Color(1.0, 0.86, 0.35, 0.55)})
	var pulse := 0.75 + 0.25 * sin(Time.get_ticks_msec() * 0.005)
	for job in merging:
		out.append({"pos": job.at, "r": forge.gather_radius_m,
			"col": Color(0.35, 0.95, 0.88, 0.30 * pulse)})
	# THE CLIMB-OUT, made visible. The alien sinks below the ground for its
	# first second and a half and cannot move — a deliberate design beat, and
	# one nobody could see, which meant the beat did not exist. A ring of dust
	# pushing outward is the cheapest thing that says "something is coming up
	# HERE" from a camera this far away.
	if fx.emerge_ring:
		for a in aliens:
			var em := float(a.get("emerge", 0.0))
			if em <= 0.0:
				continue
			var k := 1.0 - clampf(em / maxf(0.01, hive_cfg.emerge_s), 0.0, 1.0)
			var rr: float = lerpf(fx.ring_from_m, fx.ring_to_m, k)
			var col: Color = fx.ring_colour
			# Fades as it widens, so it reads as dust settling rather than a
			# marker somebody forgot to remove.
			col.a *= 1.0 - k * 0.75
			var at: Vector2 = a.pos
			for i in fx.ring_dots:
				var ang := TAU * float(i) / float(fx.ring_dots)
				out.append({"pos": at + Vector2(cos(ang), sin(ang)) * rr,
					"r": 0.42, "col": col})
	return out


## Only draw what the player can actually see. Fog is not a post effect here —
## hidden contacts are simply not submitted.
func _draw(mmi: MultiMeshInstance3D, items: Array, size_fn: Callable, col_fn: Callable) -> void:
	var n := 0
	var cap := mmi.multimesh.instance_count
	for it in items:
		if n >= cap:
			break
		var p: Vector2 = it.pos
		if not fog.is_visible(p):
			continue
		var s: Vector3 = size_fn.call(it)
		var b := Basis.IDENTITY.scaled(s)
		mmi.multimesh.set_instance_transform(n,
			Transform3D(b, Vector3(p.x, terrain.height_at(p) + s.y * 0.5, p.y)))
		mmi.multimesh.set_instance_color(n, col_fn.call(it))
		n += 1
	mmi.multimesh.visible_instance_count = n


## The box an instanced alien is drawn as, shrinking while it dies.
##
## A named function rather than a lambda: a GDScript lambda body cannot wrap
## across lines, and this one needs to.
func _alien_size(a: Dictionary) -> Vector3:
	return Vector3.ONE * tune.alien_radius_m * 2.0 * _death_scale(a)


## 0 while alive, running to 1 as a thing finishes dying.
func _death_progress(a: Dictionary) -> float:
	var left := float(a.get("dying", ALIVE))
	if left < 0.0 or fx.death_s <= 0.0:
		return 0.0
	return clampf(1.0 - left / fx.death_s, 0.0, 1.0)


func _death_scale(a: Dictionary) -> float:
	return 1.0 - fx.death_shrink * _death_progress(a)


## The colour an instanced alien is drawn in: its own, lifted toward white for
## as long as its flash lasts, and dimmed as it dies.
func _alien_tint(a: Dictionary) -> Color:
	var base := Color(1.0, 0.36, 0.45)
	var f := float(a.get("flash", 0.0))
	if f > 0.0 and fx.flash_s > 0.0:
		base = base.lerp(Color.WHITE,
			fx.flash_strength * clampf(f / fx.flash_s, 0.0, 1.0))
	var d := _death_progress(a)
	return base.darkened(d * 0.6) if d > 0.0 else base


## Flash a real node, which has materials rather than an instance colour.
##
## ONE MATERIAL, SET AND CLEARED. Walking a model's surfaces every frame to
## tint them would be dozens of parameter writes per alien; a material_override
## on the node costs one assignment and is removed the moment the flash ends,
## so a peaceful frame does nothing at all.
func _flash_node(n: Node3D, flash: float, tint: Color) -> void:
	var want := flash > 0.0 and fx.hit_flash and fx.flash_s > 0.0
	var has: bool = n.has_meta(&"flashing")
	if not want:
		if has:
			n.remove_meta(&"flashing")
			for mi in n.find_children("*", "MeshInstance3D", true, false):
				(mi as MeshInstance3D).material_override = null
		return
	var k := fx.flash_strength * clampf(flash / fx.flash_s, 0.0, 1.0)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = tint.lerp(Color.WHITE, k)
	n.set_meta(&"flashing", true)
	for mi in n.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).material_override = mat


## Tracers. Drawn separately from _draw because a shot is the one thing on the
## map whose HEIGHT is not the ground under it: a shell arcs, and a bolt flies
## at the height of the barrel that fired it rather than crawling over bumps.
func _draw_shots() -> void:
	var mm := _mm_shots.multimesh
	var n := 0
	for sh in shots:
		if n >= mm.instance_count:
			break
		var p: Vector2 = sh.pos
		if not fog.is_visible(p):
			continue
		var artillery: bool = int(sh.family) == MachinePart.Family.ARTILLERY
		# 0 at the muzzle, 1 at the target. sin() gives an arc that starts and
		# ends on the ground, which is what makes a shell read as thrown rather
		# than as a bolt that happens to be slow.
		var f := clampf(float(sh.flown) / float(sh.span), 0.0, 1.0)
		var lift := 1.1
		if artillery:
			lift += sin(f * PI) * float(sh.span) * tune.shot_arc
		var sz: float = tune.shot_size_m * (1.5 if artillery else 1.0)
		var b := Basis.IDENTITY.scaled(Vector3(sz, sz, sz * (1.0 if artillery else 2.2)))
		# Point a bolt along its flight. A stretched box that is not aligned to
		# its own direction reads as a tumbling brick.
		var dir: Vector2 = (sh.aim as Vector2) - p
		if not artillery and dir.length_squared() > 0.001:
			b = Basis(Vector3.UP, atan2(dir.x, dir.y)).scaled(
				Vector3(sz, sz, sz * 2.2))
		mm.set_instance_transform(n,
			Transform3D(b, Vector3(p.x, terrain.height_at(p) + lift, p.y)))
		mm.set_instance_color(n, Color(1.0, 0.72, 0.30) if artillery
			else Color(0.72, 1.0, 0.92))
		n += 1
	mm.visible_instance_count = n


## Health bars, two instances each: a dark back and a coloured fill.
##
## NOT A BAR OVER EVERYTHING. Seventy swarmers wearing full green bars is a
## hedge, not information. Things the player makes decisions about — machines,
## the module, the roamers and the plant nests — always carry one; a small
## alien earns one by being hurt. See ProtoConfig.bar_always_for.
func _draw_bars() -> void:
	var mm := _mm_bars.multimesh
	var n := 0
	# One basis for all of them, built from the camera. This camera has a fixed
	# pitch, so the bars only need turning once a frame, not once each.
	var face := camera.global_transform.basis
	for u in built:
		n = _bar(mm, n, face, u.pos, u.hp / maxf(1.0, u.spec.max_hp),
			u.spec.radius_m * 2.2 + tune.bar_lift_m, 1.0, true)
	for a in aliens:
		var kind: StringName = a.get("kind", &"small")
		var frac: float = float(a.hp) / maxf(1.0, float(a.get("hp_max", a.hp)))
		var always: bool = kind in tune.bar_always_for
		if not always and frac >= 0.999:
			continue
		if float(a.get("emerge", 0.0)) > 0.0:
			continue          # still climbing out; nothing to shoot at yet
		var sc := 1.0
		if kind == &"roamer":
			sc = tune.roamer_scale
		elif kind == &"nest":
			sc = tune.nest_scale
		n = _bar(mm, n, face, a.pos, frac,
			tune.bar_lift_m * sc + sc * 1.6, sc, false)
	# The module last, so it is the one that survives a full bar array.
	n = _bar(mm, n, face, module_pos, mass.mass / maxf(1.0, mass.cfg.max_mass),
		tune.bar_lift_m + _module_scale * 2.4, _module_scale * 1.3, true)
	mm.visible_instance_count = n


## One bar: the dark back, then the fill on top of it. Returns the next free
## instance slot, or the one it was given if there was no room for both — half
## a bar is worse than none, so they go in as a pair or not at all.
func _bar(mm: MultiMesh, n: int, face: Basis, at: Vector2, frac: float,
		lift: float, scale: float, friendly: bool) -> int:
	if n + 2 > mm.instance_count or not fog.is_visible(at):
		return n
	frac = clampf(frac, 0.0, 1.0)
	var w: float = tune.bar_width_m * scale
	var h: float = tune.bar_height_m * scale
	var base := Vector3(at.x, terrain.height_at(at) + lift, at.y)
	mm.set_instance_transform(n, Transform3D(bar_basis(face, w, h), base))
	mm.set_instance_color(n, Color(0.012, 0.018, 0.022))
	# Inset, and anchored LEFT rather than centred, or a bar would drain from
	# both ends at once and read as shrinking instead of emptying.
	var inner: float = w - h * 0.3
	var fw: float = maxf(0.0001, inner * frac)
	var shift: float = (fw - inner) * 0.5
	mm.set_instance_transform(n + 1, Transform3D(
		bar_basis(face, fw, h * 0.55),
		base + face.x * shift + face.z * 0.06))
	mm.set_instance_color(n + 1, _bar_colour(frac, friendly))
	return n + 2


## A card `w` wide and `h` tall, lying in the camera's plane.
##
## scaled_LOCAL, and its own function so a test can read it back. Basis.scaled()
## scales the basis ROWS, which is a world-axis scale applied on the LEFT — on
## the camera's rotated basis that is not "make this card w wide", and the first
## version of these bars came out standing on end with width and height swapped,
## as thin ticks nobody could read. Every other assertion about bars passed
## happily while it did, and the MultiMesh cannot be read back to catch it: the
## headless renderer keeps no instance transforms, so it hands back identity.
func bar_basis(face: Basis, w: float, h: float) -> Basis:
	return face.scaled_local(Vector3(w, h, 0.02))


## Green through amber to red for things the player owns; the reverse reading
## for hostiles, where a nearly-dead thing is GOOD news and should be the
## colour the eye goes to.
func _bar_colour(frac: float, friendly: bool) -> Color:
	# DARK. These are unshaded albedo, so they go through the tonemapper and
	# the ink pass untouched by any light — the first set used the HUD's own
	# colours and every bar came out the same pale mint whatever fraction it
	# was showing. Roughly half value is what survives as a colour.
	if friendly:
		if frac > 0.5:
			return Color(0.10, 0.52, 0.28).lerp(Color(0.62, 0.42, 0.04),
				(1.0 - frac) * 2.0)
		return Color(0.62, 0.42, 0.04).lerp(Color(0.66, 0.07, 0.09),
			1.0 - frac * 2.0)
	return Color(0.66, 0.09, 0.16).lerp(Color(0.62, 0.42, 0.04), 1.0 - frac)


## Give every convoy member a real body, and point the aiming parts at what
## they are shooting. Individual nodes rather than MultiMesh: the convoy is a
## dozen things, and nodes buy animated sub-parts for free.
func _sync_convoy() -> void:
	# Keyed by uid, not by index. Machines leave the array from the middle all
	# the time now — a merge takes two out at once — and an index-keyed pool
	# would quietly hand a Siege Battery the Skirmisher's body.
	var live := {}
	for u in built:
		live[u.uid] = true
		if _unit_nodes.has(u.uid):
			continue
		var n: Node3D = lib.spawn(String(u.opt.model)) if String(u.opt.model) != "" else null
		if n == null:
			n = Node3D.new()
		add_child(n)
		_unit_nodes[u.uid] = n
	for uid in _unit_nodes.keys():
		if not live.has(uid):
			(_unit_nodes[uid] as Node3D).queue_free()
			_unit_nodes.erase(uid)

	for i in built.size():
		var u: Dictionary = built[i]
		var p: Vector2 = u.pos
		var n: Node3D = _unit_nodes[u.uid]
		n.visible = fog.is_visible(p)
		if not n.visible:
			continue
		n.position = Vector3(p.x, terrain.height_at(p), p.y)
		_flash_node(n, float(u.get("flash", 0.0)), fx.flash_friendly)
		var aim := String(u.opt.aim_node)
		if aim == "":
			continue
		var part := n.find_child(aim, true, false)
		if part == null:
			continue
		var t := _nearest_alien(p, u.opt.range_m if u.opt.damage > 0.0 else 40.0)
		# Nothing to shoot: sweep slowly, so an idle turret still looks alive.
		var sweep := Time.get_ticks_msec() * 0.0006
		var face: Vector2 = (aliens[t].pos - p) if t >= 0 else Vector2(cos(sweep), sin(sweep))
		(part as Node3D).rotation.y = atan2(face.x, face.y)


## Skinned meshes cannot be instanced through MultiMesh, so animated aliens are
## individual nodes and the rest fall back to cheap boxes past the cap. That is
## the tradeoff in the open: readable animation, or crowd size.
func _sync_aliens() -> void:
	var animated := mini(aliens.size(), tune.animated_alien_cap)
	while _alien_nodes.size() < animated:
		var heavy := _rng.randf() < tune.breacher_share
		var n: Node3D = lib.spawn(tune.breacher_model if heavy else tune.swarmer_model)
		if n == null:
			n = Node3D.new()
		add_child(n)
		var ap := n.find_child("AnimationPlayer", true, false) as AnimationPlayer
		if ap != null:
			var clip := ModelLibrary.pick_animation(ap, "walk" if heavy else "run")
			if clip != "":
				ap.play(clip)
				ap.speed_scale = 0.8 if heavy else 1.35
		_alien_nodes.append(n)
	while _alien_nodes.size() > animated:
		var dead: Node3D = _alien_nodes.pop_back()
		dead.queue_free()

	for i in animated:
		var a: Dictionary = aliens[i]
		var p: Vector2 = a.pos
		var n: Node3D = _alien_nodes[i]
		n.visible = fog.is_visible(p)
		if not n.visible:
			continue
		n.position = Vector3(p.x, terrain.height_at(p), p.y)
		# A roamer is the biggest living thing on the map and a nest is a
		# plant; both are aliens in the array and both have to LOOK like what
		# they are, or the player cannot tell which one killing stops a brood.
		var kind: StringName = a.get("kind", &"small")
		var sc := 1.0
		if kind == &"roamer":
			sc = tune.roamer_scale
		elif kind == &"nest":
			sc = tune.nest_scale
		# Sunk while it climbs out, so emerging is something you can watch.
		var em := float(a.get("emerge", 0.0))
		if em > 0.0:
			n.position.y -= sc * 0.9 * clampf(em / maxf(0.01, hive_cfg.emerge_s),
				0.0, 1.0)
		# AND SUNK AGAIN WHILE IT DIES, keeling over as it goes. The same trick
		# at the other end of its life: something that sinks into the ground
		# reads as a body, and something that blinks out reads as a bug.
		var fall := _death_progress(a)
		n.scale = Vector3.ONE * sc * _death_scale(a)
		var to := module_pos - p
		if to.length_squared() > 0.01:
			n.rotation.y = atan2(to.x, to.y)
		n.rotation.x = 0.0
		if fall > 0.0:
			n.position.y -= sc * fx.death_sink_m * fall
			n.rotation.x = fx.death_tip_rad * fall
		_flash_node(n, float(a.get("flash", 0.0)),
			Color(1.0, 0.36, 0.45))


func _hud(delta: float) -> void:
	# The mockup's layout: the module's mass along the top, the map in the
	# corner, the radar and the build tiles down the right, what the drone is
	# doing in the middle, and one strip along the bottom. Panels on the edges,
	# battlefield in the middle — which on a phone also keeps both thumbs off
	# the part of the screen being looked at.
	mass_label.text = "MODULE MASS   %.0f / %.0f" % [mass.mass, mass.cfg.max_mass]
	mass_bar.max_value = mass.cfg.max_mass
	mass_bar.value = mass.mass
	seen_label.text = "VISIBLE AREA   %.0f%%      MODULE x%.2f" \
		% [fog.explored_fraction() * 100.0, _module_scale]

	mode_label.text = "TRENCH — DRAG TO DIG" if trenching else "EXPLORE"
	mode_label.add_theme_color_override("font_color",
		Color(1.0, 0.78, 0.35) if trenching else Color(0.65, 1.0, 0.92))

	tally_label.text = "BUILT %d%s      HOSTILES %d      WRECKS %d" \
		% [built.size(), _assembly_note(), _live_hostiles(), wrecks.size()]

	strip_label.text = "MASS POOL  %.0f        RESERVE  %.0f        FORGE  %s" \
		% [mass.mass, mass.cfg.reserve_mass, _forge_note()]

	# Radar: what the module can currently see, which is the thing the reveal
	# radius on a Watcher is actually buying.
	var reveal := 0
	for u in built:
		if u.spec.reveal_m > 0.0:
			reveal += 1
	radar_label.text = "RADAR\ncontacts %d    debris %d\n%d machines watching" \
		% [_live_hostiles(), _loose_debris(), reveal]

	_drone_panel()
	_alert_line()

	# One repaint a frame is cheap at this size, and the blips move every frame.
	mini.blips = _blips()
	mini.module_pos = module_pos
	mini.view_centre = Vector2(rig.position.x, rig.position.z)
	mini.view_radius = 34.0
	mini.queue_redraw()

	if _toast_t > 0.0:
		_toast_t -= delta
		if _toast_t <= 0.0:
			toast.text = ""


## The target panel, bottom right: what the drone is on and how long it has.
func _drone_panel() -> void:
	# ALWAYS VISIBLE WHEN IDLE, now that idle is the drone's resting state
	# rather than a half-second between jobs it found for itself. A panel that
	# hides when there is nothing to do reads as "the drone is broken" when the
	# truth is "the drone is waiting for you".
	if drone_target < 0 and drone_state == "idle":
		target_panel.visible = true
		var loose := _loose_debris()
		target_label.text = "DRONE  idle\ntap a piece to collect it" if loose > 0 \
			else "DRONE  idle\nnothing left in sight"
		return
	target_panel.visible = true
	var what := "wreck"
	var left := 0.0
	if drone_target >= 0:
		var large := _is_large_job(drone_target)
		what = "large debris" if large else "debris"
		var need: float = tune.large_free_s if large else tune.small_free_s
		left = maxf(0.0, need - free_progress)
	match drone_state:
		"outbound":
			target_label.text = "TARGET  %s\nflying out" % what
		"working":
			target_label.text = "TARGET  %s\nfreeing  %.0f%%   %.0fs left" \
				% [what, free_progress / maxf(0.01, left + free_progress) * 100.0, left]
		"returning":
			target_label.text = "HAULING  %.0f mass\nback to the module" % drone_cargo
		_:
			target_label.text = "DRONE  idle"


## The alert line and the job bar, centre screen — the one place the player is
## already looking when something goes wrong.
func _alert_line() -> void:
	if waves.is_active():
		alert_label.text = "CRITICAL — freeing that piece has woken them. Hold."
		job_bar.visible = _is_large_job(drone_target)
		if job_bar.visible:
			job_bar.max_value = tune.large_free_s
			job_bar.value = free_progress
	else:
		alert_label.text = ""
		job_bar.visible = false


## Hostiles that are still a threat. Corpses spend a third of a second on the
## map after they die and must not be counted: a tally that says 3 when
## everything is dead is a tally nobody trusts again.
func _live_hostiles() -> int:
	var n := 0
	for a in aliens:
		if float(a.get("dying", ALIVE)) < 0.0:
			n += 1
	return n


func _loose_debris() -> int:
	var n := 0
	for d in debris:
		if not d.taken:
			n += 1
	return n


## Everything the corner map draws. Deliberately plain dictionaries: the
## minimap knows nothing about units, debris or wrecks — it draws dots.
func _blips() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for d in debris:
		if d.taken or not fog.level_at(d.pos) > 0.0:
			continue
		out.append({"pos": d.pos, "size": 3.2 if d.large else 2.0,
			"colour": Color(1.0, 0.62, 0.28) if d.large else Color(0.85, 0.74, 0.42)})
	for w in wrecks:
		out.append({"pos": w.pos, "size": 2.4, "colour": Color(0.60, 0.62, 0.70)})
	for u in built:
		out.append({"pos": u.pos, "size": 2.6, "colour": u.spec.colour})
	for a in aliens:
		if fog.is_visible(a.pos):
			out.append({"pos": a.pos, "size": 2.4, "colour": Color(1.0, 0.36, 0.45)})
	out.append({"pos": drone_pos, "size": 2.6, "colour": Color(0.55, 0.85, 1.0)})
	out.append({"pos": module_pos, "size": 5.0, "colour": Color(0.35, 1.0, 0.86)})
	return out


## What the build queue is doing, for the one line of HUD it deserves.
func _assembly_note() -> String:
	if assembling.is_empty():
		return ""
	var soonest := INF
	for job in assembling:
		soonest = minf(soonest, job.left)
	return "  (+%d in %.0fs)" % [assembling.size(), ceilf(soonest)]


## What the reforge orders are doing, for the HUD.
func _forge_note() -> String:
	if merging.is_empty():
		return "—" if selected.is_empty() else "%d selected" % selected.size()
	var parts := PackedStringArray()
	for job in merging:
		if job.state == "gathering":
			parts.append("%s converging" % job.spec.display_name)
		else:
			parts.append("%s %.0fs" % [job.spec.display_name, ceilf(job.left)])
	return ", ".join(parts)


func _say(text: String) -> void:
	toast.text = text
	_toast_t = 3.0


## Steep, but not straight down.
##
## The reference survey map is drawn flat overhead, and a camera that copies it
## exactly would hide every silhouette in the game: the arches, the spires and
## the machines all become circles. This sits about seventy degrees down, which
## reads as the survey map while leaving the props something to be seen by.
##
## Landscape, so the useful axis is width: the camera sits further back and the
## side panels take the edges rather than the battlefield.
func _frame_camera() -> void:
	# THE RIG RIDES THE GROUND. It used to sit at y = 0 while the biodome floor
	# is around y = 21, which was invisible at the shipped camera height of 48
	# and fatal the moment the zoom came in: the closest rung puts the camera
	# at 18 m, three metres UNDERNEATH the map, and the frame renders black.
	# Aiming at y = 0 was also why the middle rung pushed the module to the top
	# of the screen — look_at was pointing at a spot below the terrain.
	rig.position.y = terrain.height_at(
		Vector2(rig.position.x, rig.position.z))
	camera.position = tune.camera_offset * _zoom + _shake_offset()
	camera.look_at(rig.global_position, Vector3.UP)
	camera.fov = tune.camera_fov_deg


## Where the shake has pushed the camera this instant.
##
## ADDED TO THE OFFSET, not to the rig. The rig is the view centre — the pan,
## the leash and the minimap all read it — and shaking it would make the camera
## drag the world's idea of where the player is looking. The camera moves; what
## it is looking AT does not.
##
## Two axes at different rates so it does not read as a single line, and the
## look_at afterwards means a moved camera still points at the same ground.
func _shake_offset() -> Vector3:
	if _shake <= 0.0001:
		return Vector3.ZERO
	var t := _shake_t * TAU * fx.shake_hz
	return Vector3(sin(t) * _shake, sin(t * 1.37 + 1.1) * _shake * 0.6,
		cos(t * 0.91) * _shake)


## How far the camera clears the ground directly beneath it at the current
## rung. Its own function so a check can assert it is positive at every rung —
## a camera under the map is a black screen with no error anywhere.
func camera_clearance() -> float:
	var at := camera.global_position
	return at.y - terrain.height_at(Vector2(at.x, at.z))


## Where the selected rung says the camera should be.
func _zoom_target() -> float:
	if tune.camera_zoom_steps.is_empty():
		return 1.0
	return tune.camera_zoom_steps[clampi(zoom_step, 0,
		tune.camera_zoom_steps.size() - 1)]


## Step to the next rung and wrap. This is what the ZOOM button does; the pinch
## sets `_zoom` directly and then settles onto whichever rung is nearest.
func cycle_zoom() -> void:
	if tune.camera_zoom_steps.is_empty():
		return
	zoom_step = (zoom_step + 1) % tune.camera_zoom_steps.size()
	_say("ZOOM  %s" % _zoom_name())


## The button says which rung it is ON, not which one it will go to. A control
## that reports its own state is one fewer thing to remember.
func _refresh_zoom_button() -> void:
	if _zoom_button != null:
		_zoom_button.text = "ZOOM\n%s" % _zoom_name()


func _zoom_name() -> String:
	match zoom_step:
		0: return "wide"
		1: return "middle"
		_: return "close"


## After a pinch, land on the rung the player stopped nearest to. The gesture
## is continuous so it feels live, but the game still has three named levels
## and the next tap of the button continues from a known one.
func _settle_zoom() -> void:
	var best := 0
	var bd := 1e9
	for i in tune.camera_zoom_steps.size():
		var d: float = absf(tune.camera_zoom_steps[i] - _zoom)
		if d < bd:
			bd = d
			best = i
	zoom_step = best
	_refresh_zoom_button()


## Ease toward the selected rung. Presentation, not simulation: where the
## camera is has no effect on anything the sim does.
func _ease_zoom(delta: float) -> void:
	var want := _zoom_target()
	if absf(_zoom - want) < 0.001:
		return
	_zoom = lerpf(_zoom, want, clampf(tune.camera_zoom_lerp * delta, 0.0, 1.0))
	_frame_camera()


## Keep the module in view without nailing the view to it.
##
## A camera hard-locked to the module cannot be panned: every sim step would
## snap it back. A camera that never follows loses the module the moment it
## walks. So: a leash. Inside camera_leash_m of the view centre the player's
## pan is left exactly where they put it; past it the rig eases along, which
## is also the signal that the module is about to leave the screen.
func _follow_module(delta: float) -> void:
	var off := module_pos - Vector2(rig.position.x, rig.position.z)
	# SCALED BY THE ZOOM, because the leash is really "how far off centre may
	# the module get before it leaves the screen", and the screen covers less
	# ground the closer the camera is. A fixed leash loses the module the
	# moment the player zooms in.
	var slack := off.length() - tune.camera_leash_m * _zoom
	if slack <= 0.0:
		return
	var pull := off.normalized() * slack * clampf(
		tune.camera_follow * delta, 0.0, 1.0)
	rig.position += Vector3(pull.x, 0.0, pull.y)
	_frame_camera()


# --- input -------------------------------------------------------------------
var _drag := false
var _panned := false
var _press := Vector2.ZERO
## Every finger currently down, by touch index. A pinch needs two of them and
## the pan needs to know when a second one arrives, because a two-finger drag
## is a zoom and dragging the map at the same time reads as the map lurching.
var _touches: Dictionary = {}
## Finger spread when the pinch started, and the zoom it started from.
var _pinch_from := 0.0
var _pinch_zoom := 1.0


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_touch(event)
	elif event is InputEventScreenDrag:
		_touches[event.index] = event.position
		if _touches.size() >= 2:
			_pinch()
		elif _drag:
			_one_finger_drag(event)
	elif event is InputEventMagnifyGesture:
		# Trackpads and some Android builds send this instead of two touches.
		_zoom = clampf(_zoom / maxf(0.2, event.factor), _zoom_min(), _zoom_max())
		_settle_zoom()
		_frame_camera()
	elif event is InputEventMouseButton and event.pressed:
		# Desktop only, and only so the three rungs can be tested without a
		# touchscreen. A phone never sends this.
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_nudge_zoom(-0.08)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_nudge_zoom(0.08)


func _touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		_touches[event.index] = event.position
		if _touches.size() == 2:
			# A pinch is starting. Whatever the first finger was doing, it was
			# not this — cancel the pan and the pending tap so lifting off does
			# not also issue a move order.
			_drag = false
			_panned = true
			_pinch_from = _spread()
			_pinch_zoom = _zoom
		elif _touches.size() == 1:
			_drag = true
			_panned = false
			_press = event.position
		return
	_touches.erase(event.index)
	if _touches.is_empty():
		var was_pinching := _panned and not _drag
		if _drag and not _panned:
			_tap(event.position)
		_drag = false
		if was_pinching:
			_settle_zoom()
	elif _touches.size() == 1:
		# One finger left after a pinch. Do NOT resume panning with it — the
		# hand is halfway through a gesture and the map would jump.
		_drag = false
		_panned = true


func _one_finger_drag(event: InputEventScreenDrag) -> void:
	if _press.distance_to(event.position) > 14.0:
		_panned = true
	if trenching:
		var hit: Variant = terrain.raycast(
			camera.project_ray_origin(event.position),
			camera.project_ray_normal(event.position))
		if hit != null:
			var h: Vector3 = hit
			_dig(Vector2(h.x, h.z), get_process_delta_time())
	elif _panned:
		# Scaled by the zoom, so a drag moves the ground under the thumb by the
		# same distance whatever the camera height. Unscaled, panning zoomed in
		# flings the map off the screen.
		rig.position += Vector3(-event.relative.x, 0.0, -event.relative.y) \
			* 0.09 * _zoom
		_frame_camera()          # re-seats the rig on the ground it just moved over


## Distance between the first two fingers down.
func _spread() -> float:
	var pts: Array = _touches.values()
	if pts.size() < 2:
		return 0.0
	return (pts[0] as Vector2).distance_to(pts[1] as Vector2)


## FINGERS APART MEANS CLOSER. The zoom is a multiplier on the camera offset,
## so spreading the fingers has to make that multiplier SMALLER — the ratio
## goes on the bottom.
func _pinch() -> void:
	var now := _spread()
	if _pinch_from < tune.pinch_deadzone_px or now < tune.pinch_deadzone_px:
		return
	var ratio := now / _pinch_from
	if tune.pinch_gain != 1.0:
		ratio = pow(ratio, tune.pinch_gain)
	_zoom = clampf(_pinch_zoom / ratio, _zoom_min(), _zoom_max())
	_frame_camera()


func _nudge_zoom(by: float) -> void:
	_zoom = clampf(_zoom + by, _zoom_min(), _zoom_max())
	_settle_zoom()
	_frame_camera()


## The rungs are widest first, so the closest rung is the smallest multiplier.
## Read from the table rather than assumed, or editing it in the inspector
## would silently clamp the new range away.
func _zoom_min() -> float:
	var m := 1.0
	for z in tune.camera_zoom_steps:
		m = minf(m, z)
	return m


func _zoom_max() -> float:
	var m := 0.0
	for z in tune.camera_zoom_steps:
		m = maxf(m, z)
	return maxf(m, 0.01)


## Tap the ground to drive the module. Tap a large piece to send the drone at
## it — which is how the player chooses to start a fight.
func _tap(screen: Vector2) -> void:
	var hit: Variant = terrain.raycast(camera.project_ray_origin(screen),
		camera.project_ray_normal(screen))
	if hit == null:
		return
	var p := Vector2(hit.x, hit.z)

	# A machine first. Tapping one selects it; tapping it again drops it. That
	# is the whole selection model — no drag box, no modifier key, nothing that
	# needs a second hand on a phone.
	var nearest := -1
	var nd := 2.2
	for i in built.size():
		var d: float = built[i].pos.distance_to(p)
		if d < nd:
			nd = d
			nearest = i
	if nearest >= 0:
		var uid: int = built[nearest].uid
		if selected.has(uid):
			selected.erase(uid)
		elif selected.size() >= forge.max_group:
			_say("%d is the most that can combine at once" % forge.max_group)
		else:
			selected.append(uid)
		return
	if not selected.is_empty():
		selected.clear()
		return

	# ANY piece, not just a large one. With auto-collect gone this tap is the
	# only way mass ever reaches the module, so it has to reach wrecks and
	# small debris too, not just the one that starts a fight.
	var job := _job_near(p, tune.drone_order_reach_m)
	if job >= 0:
		drone_target = job
		drone_state = "outbound"
		free_progress = 0.0
		if _is_large_job(job):
			_say("Freeing that piece will wake them. Build first if you need to.")
		elif job >= 1000:
			_say("Recovering the wreck.")
		else:
			_say("Collecting.")
		return
	if trenching:
		_dig(p, 0.35)          # a tap is a short bite; drag digs continuously
		return
	if field.is_passable(p):
		# A GOAL, NOT A POSITION. Setting module_pos here is what made the
		# module read as respawning wherever you tapped: it was not moving, it
		# was being re-placed, and the camera cut with it. _walk_module drives
		# it there now, which also means it can be caught out of position —
		# which is the whole point of a body that carries your mass.
		module_goal = p
