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

const MAP := "res://data/terrain/test_map_01.tres"
const MASS_CFG := "res://data/gameplay/mass.tres"
const WAVES := "res://data/waves/biodome_01.tres"
const OPTIONS_DIR := "res://data/gameplay/build_options/"
const TERRAIN_SHADER := "res://shaders/terrain_lit.gdshader"
const LIGHT_CFG := "res://data/gameplay/lighting.tres"

const PROTO_CFG := "res://data/gameplay/proto.tres"
const FOG_HZ := 15.0        ## presentation cadence, not a gameplay number

@onready var terrain: TerrainView = $Terrain
@onready var module: Node3D = $Module
@onready var drone: Node3D = $Drone
@onready var rig: Node3D = $CameraRig
@onready var sun: DirectionalLight3D = $Sun
@onready var world_env: WorldEnvironment = $WorldEnvironment
@onready var camera: Camera3D = $CameraRig/Camera3D
@onready var readout: Label = $HUD/Panel/Readout
@onready var toast: Label = $HUD/Panel/Toast
@onready var build_bar: HBoxContainer = $HUD/Build

var field: Heightfield
var fog: FogOfWar
var mass: MassPool
var waves: WaveDirector
var options: Array[BuildOption] = []
var tune: ProtoConfig

var module_pos := Vector2.ZERO
var drone_pos := Vector2.ZERO
var drone_state := "idle"          # idle | outbound | working | returning
var drone_target := -1
var drone_cargo := 0.0
var drone_cargo_is_wreck := false
var free_progress := 0.0

var debris: Array[Dictionary] = []
var built: Array[Dictionary] = []
var aliens: Array[Dictionary] = []
var wrecks: Array[Dictionary] = []

var _mm_debris: MultiMeshInstance3D
var _mm_built: MultiMeshInstance3D
var _mm_aliens: MultiMeshInstance3D
var _module_scale := 1.0
var _toast_t := 0.0
var _fog_cd := 0.0
var trenching := false
var _rng := RandomNumberGenerator.new()
var lib := ModelLibrary.new()
var _module_body: Node3D = null
var _module_form := -1
var _unit_nodes: Array[Node3D] = []
var _alien_nodes: Array[Node3D] = []


func _ready() -> void:
	_rng.seed = 20260913
	tune = load(PROTO_CFG)
	# Final-quality lighting, applied from data. Frame-rate work measured
	# without shadows and a lit sky measures a game nobody ships.
	LightingRig.apply(load(LIGHT_CFG), sun, world_env)
	var map: TerrainMap = load(MAP)
	field = TerrainBuilder.build(map)
	var cfg := field.cfg

	fog = FogOfWar.new(Vector2i(cfg.cells_x, cfg.cells_z), cfg.cell_size_m)
	terrain.setup(field, fog, load(TERRAIN_SHADER))

	mass = MassPool.new(load(MASS_CFG))
	mass.rejected.connect(func(why): _say(why))
	waves = WaveDirector.new(load(WAVES))
	waves.spawn_due.connect(_spawn_hostiles)
	waves.wave_began.connect(func(_s, _i): _say("THEY HAVE NOTICED — hold until it is free"))
	waves.wave_ended.connect(func(_s): _say("THE PIECE IS FREE — the attack breaks off"))

	_load_options()
	module_pos = map.spawn
	drone_pos = module_pos + Vector2(3.0, 0.0)
	_scatter_debris()
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
	for f in DirAccess.get_files_at(OPTIONS_DIR):
		if f.ends_with(".tres"):
			options.append(load(OPTIONS_DIR + f))
	options.sort_custom(func(a, b): return a.mass_cost < b.mass_cost)


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


func _make_instancers() -> void:
	_mm_debris = _instancer(_chunk_mesh(Color(0.85, 0.74, 0.42)), 64)
	_mm_built = _instancer(_chunk_mesh(Color(0.31, 0.89, 0.76)), 96)
	_mm_aliens = _instancer(_chunk_mesh(Color(1.0, 0.36, 0.45)), 192)


func _chunk_mesh(c: Color) -> Mesh:
	var m := BoxMesh.new()
	m.size = Vector3(0.9, 0.9, 0.9)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = c
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.7
	m.material = mat
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


func _build_menu() -> void:
	var dig := Button.new()
	dig.text = "TRENCH"
	dig.toggle_mode = true
	dig.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dig.add_theme_font_size_override("font_size", 19)
	dig.toggled.connect(func(on): trenching = on)
	build_bar.add_child(dig)
	for opt in options:
		var b := Button.new()
		b.text = "%s\n%d" % [opt.display_name, int(opt.mass_cost)]
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 19)
		b.pressed.connect(_try_build.bind(opt))
		build_bar.add_child(b)


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
	_drone(delta)
	_units(delta)
	_hostiles(delta)
	waves.tick(delta)

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
			if u.opt.reveal_m > 0.0:
				fog.reveal(u.pos, u.opt.reveal_m)


## The drone is the only thing that moves mass. Everything else spends it.
func _drone(delta: float) -> void:
	match drone_state:
		"idle":
			var next := _nearest_job()
			if next >= 0:
				drone_target = next
				drone_state = "outbound"
			else:
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


## Wrecks first — recovering your own losses should never queue behind
## exploring, or a bad fight compounds itself.
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
## was put — and it still costs body, because nothing here is free.
func _dig(at: Vector2, delta: float) -> void:
	var cost: float = tune.trench_mass_per_s * delta
	if not mass.can_afford(cost):
		_say("not enough mass to keep digging")
		trenching = false
		return
	mass.mass -= cost
	mass.changed.emit(mass.mass, -cost)
	field.deform(at, tune.trench_radius_m, tune.trench_rate_per_s * delta)
	terrain.mark_dirty()


func _try_build(opt: BuildOption) -> void:
	if not mass.spend(opt.mass_cost):
		return
	var a := _rng.randf() * TAU
	var p := module_pos + Vector2(cos(a), sin(a)) * (3.0 + _module_scale)
	built.append({
		"opt": opt, "pos": p, "hp": opt.max_hp, "cd": 0.0,
		"slot": built.size(),
	})
	_say("%s built — %d mass spent" % [opt.display_name, int(opt.mass_cost)])


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
		var upos: Vector2 = u.pos
		var station := _station(i, built.size(), u.opt)
		var gap := station - upos
		var dist := gap.length()
		if dist > 0.05:
			# A spring, not a leash: something left behind closes faster, so
			# the convoy regroups instead of stringing out across the map.
			var urgency := 1.0 + (dist / maxf(1.0, tune.escort_radius_m)) * tune.escort_catchup
			var speed: float = u.opt.escort_speed_mps * urgency
			u.pos = upos + gap / dist * minf(speed * delta, dist)
		if u.opt.damage > 0.0 and u.cd <= 0.0:
			var upos3: Vector2 = u.pos
			var t := _nearest_alien(upos3, u.opt.range_m)
			if t >= 0:
				aliens[t].hp -= u.opt.damage
				u.cd = u.opt.cooldown_s
		if u.hp <= 0.0:
			# Not deleted — it becomes a wreck the drone can recover.
			wrecks.append({"pos": u.pos, "mass": u.opt.mass_cost, "wreck": true})
			built.remove_at(i)
			_say("%s lost — wreck marked for recovery" % u.opt.display_name)


## Evenly spaced ring position for one convoy member.
func _station(slot: int, total: int, opt: BuildOption) -> Vector2:
	var r: float = opt.escort_radius_m if opt.escort_radius_m > 0.0 else tune.escort_radius_m
	var a := TAU * (float(slot) / maxf(1.0, float(total)))
	return module_pos + Vector2(cos(a), sin(a)) * (r + _module_scale)


func _nearest_alien(from: Vector2, rng: float) -> int:
	var best := -1
	var bd := rng
	for i in aliens.size():
		var ap: Vector2 = aliens[i].pos
		var d := ap.distance_to(from)
		if d < bd:
			bd = d
			best = i
	return best


func _spawn_hostiles(count: int, intensity: float) -> void:
	var cfg := field.cfg
	for i in count:
		var a := _rng.randf() * TAU
		var p := module_pos + Vector2(cos(a), sin(a)) * lerpf(
			tune.spawn_ring_m.x, tune.spawn_ring_m.y, _rng.randf())
		p.x = clampf(p.x, 2.0, cfg.cells_x - 2.0)
		p.y = clampf(p.y, 2.0, cfg.cells_z - 2.0)
		aliens.append({"pos": p, "hp": waves.hostile_hp(), "cd": 0.0})


func _hostiles(delta: float) -> void:
	for i in range(aliens.size() - 1, -1, -1):
		var al := aliens[i]
		if al.hp <= 0.0:
			aliens.remove_at(i)
			continue
		al.cd -= delta
		var apos: Vector2 = al.pos
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
					u.hp -= tune.alien_damage
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


# --- presentation ------------------------------------------------------------
func _present(delta: float) -> void:
	# The module IS the mass readout. Ease toward the target so spending reads
	# as a visible shrink rather than a pop.
	var want := mass.display_scale()
	_module_scale = lerpf(_module_scale, want,
		clampf(delta / maxf(0.01, mass.cfg.scale_tween_s), 0.0, 1.0))
	module.scale = Vector3.ONE * _module_scale
	_set_module_form(_form_for_mass())
	module.position = Vector3(module_pos.x, terrain.height_at(module_pos), module_pos.y)
	drone.position = Vector3(drone_pos.x, terrain.height_at(drone_pos) + 5.5, drone_pos.y)
	for r in drone.find_children("rotor_*", "Node3D", true, false):
		(r as Node3D).rotate_y(delta * 26.0)

	_draw(_mm_debris, debris.filter(func(d): return not d.taken),
		func(d): return Vector3(0.9, 0.9, 0.9) * (2.3 if d.large else 1.0),
		func(d): return Color(1.0, 0.62, 0.28) if d.large else Color(0.85, 0.74, 0.42))
	_sync_convoy()
	_sync_aliens()
	_draw(_mm_aliens, aliens.slice(mini(aliens.size(), tune.animated_alien_cap)),
		func(_a): return Vector3.ONE * tune.alien_radius_m * 2.0,
		func(_a): return Color(1.0, 0.36, 0.45))

	terrain.upload()
	fog.upload(delta)
	_hud(delta)


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


## Give every convoy member a real body, and point the aiming parts at what
## they are shooting. Individual nodes rather than MultiMesh: the convoy is a
## dozen things, and nodes buy animated sub-parts for free.
func _sync_convoy() -> void:
	while _unit_nodes.size() < built.size():
		var u: Dictionary = built[_unit_nodes.size()]
		var n: Node3D = lib.spawn(String(u.opt.model)) if String(u.opt.model) != "" else null
		if n == null:
			n = Node3D.new()
		add_child(n)
		_unit_nodes.append(n)
	while _unit_nodes.size() > built.size():
		var dead: Node3D = _unit_nodes.pop_back()
		dead.queue_free()

	for i in built.size():
		var u: Dictionary = built[i]
		var p: Vector2 = u.pos
		var n: Node3D = _unit_nodes[i]
		n.visible = fog.is_visible(p)
		if not n.visible:
			continue
		n.position = Vector3(p.x, terrain.height_at(p), p.y)
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
		var to := module_pos - p
		if to.length_squared() > 0.01:
			n.rotation.y = atan2(to.x, to.y)


func _hud(delta: float) -> void:
	var job := "idle"
	match drone_state:
		"outbound": job = "flying out"
		"returning": job = "hauling %.0f" % drone_cargo
		"working":
			job = "freeing"
			if _is_large_job(drone_target):
				job = "freeing %.0f%%" % (free_progress / tune.large_free_s * 100.0)
	readout.text = "\n".join([
		"MASS   %.0f   (reserve %.0f)" % [mass.mass, mass.cfg.reserve_mass],
		"MODULE x%.2f" % _module_scale,
		"DRONE  %s" % job,
		"BUILT  %d   HOSTILES %d   WRECKS %d" % [built.size(), aliens.size(), wrecks.size()],
		"SEEN   %.0f%%" % (fog.explored_fraction() * 100.0),
		"ATTACK %s" % ("INCOMING" if waves.is_active() else "quiet"),
		"MODE   %s" % ("TRENCH — drag to dig" if trenching else "move"),
	])
	if _toast_t > 0.0:
		_toast_t -= delta
		if _toast_t <= 0.0:
			toast.text = ""


func _say(text: String) -> void:
	toast.text = text
	_toast_t = 3.0


func _frame_camera() -> void:
	camera.position = Vector3(0.0, 26.0, 22.0)
	camera.look_at(rig.global_position, Vector3.UP)
	camera.fov = 62.0


# --- input -------------------------------------------------------------------
var _drag := false
var _panned := false
var _press := Vector2.ZERO


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_drag = true
			_panned = false
			_press = event.position
		else:
			_drag = false
			if not _panned:
				_tap(event.position)
	elif event is InputEventScreenDrag and _drag:
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
			rig.position += Vector3(-event.relative.x, 0.0, -event.relative.y) * 0.09
			_frame_camera()


## Tap the ground to drive the module. Tap a large piece to send the drone at
## it — which is how the player chooses to start a fight.
func _tap(screen: Vector2) -> void:
	var hit: Variant = terrain.raycast(camera.project_ray_origin(screen),
		camera.project_ray_normal(screen))
	if hit == null:
		return
	var p := Vector2(hit.x, hit.z)
	for i in debris.size():
		if debris[i].taken or not debris[i].large:
			continue
		if debris[i].pos.distance_to(p) < 4.0:
			drone_target = i
			drone_state = "outbound"
			_say("Freeing that piece will wake them. Build first if you need to.")
			return
	if trenching:
		_dig(p, 0.35)          # a tap is a short bite; drag digs continuously
		return
	if field.is_passable(p):
		module_pos = p
		rig.position = Vector3(p.x, 0.0, p.y)
		_frame_camera()
