extends SceneTree
## Drive the prototype like a player would and FILM IT.
##
##   tools/playthrough.sh [seconds] [WxH]
##
## proto_drive.gd already proves the loop turns, by asserting state. It runs
## headless, so it can say the module moved and cannot say whether the movement
## READS — whether a walk looks like walking, whether a hit looks like a hit,
## whether the camera settles or lurches.
##
## This is the other half. It boots the real scene on the real rasteriser,
## issues a scripted sequence of orders, and captures a frame every so often
## into a filmstrip, while logging the numbers that say what the motion is
## doing between frames: distance walked per second, the camera's lag behind
## the module, how many shots are in the air, how hard the camera is shaking.
##
## A filmstrip is not play. Nobody can tell from it whether the module feels
## heavy or the shake feels cheap — those are the questions CLAUDE.md says to
## stop and ask about. What it CAN settle is whether anything is visibly
## broken: a module that teleports, a camera that never catches up, an effect
## that fires and draws nothing.

const OUT_DIR := "res://build/play"
var _frames := 0
var _shots_fired := 0
var _t := 0.0
var _grabs: Array = []
var _log: Array = []
var _scene: Node3D
var _last_module := Vector2.ZERO
var _peak_shake := 0.0
var _seconds := 24.0
var _every := 1.5          # seconds between captured frames
var _next_grab := 0.0
var _started := false


func _initialize() -> void:
	var argv := OS.get_cmdline_user_args()
	if argv.size() > 0:
		_seconds = float(argv[0])
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(OUT_DIR))
	var ps: PackedScene = load("res://scenes/proto/proto_main.tscn")
	_scene = ps.instantiate()
	root.add_child(_scene)
	print("SENTINEL — playthrough, %.0f s at %s\n"
		% [_seconds, RenderingServer.get_video_adapter_name()])


func _process(delta: float) -> bool:
	if not _started:
		_started = true
		_last_module = _scene.module_pos
		return false
	_t += delta
	_frames += 1

	# --- the script of play -------------------------------------------------
	# Beats chosen so each thing that MOVES gets a turn on camera: the module
	# walking, the drone flying a job, a fight with tracers and beams, and the
	# camera being hit hard enough to shake.
	if _frames == 20:
		_reveal()
		_scene.call("_stress")
		print("  %5.1fs  stress load: machines and hostiles on the field" % _t)
		# WALK SOMEWHERE. module_goal is the order; _walk_module closes on it
		# at 3.6 m/s. Far enough that the camera leash has to do some work,
		# and along the map rather than into the ravine.
		_scene.module_goal = _scene.module_pos + Vector2(26.0, 14.0)
		print("  %5.1fs  ordered the module to %+.0f,%+.0f"
			% [_t, _scene.module_goal.x, _scene.module_goal.y])
		# BUILD AN ARTILLERY PIECE, because otherwise the camera never shakes
		# and it looks like the shake is broken. _stress() picks the heaviest
		# machine plus one beam and one shield — it does not guarantee a SPLASH
		# weapon, and EffectsConfig.shake_splash_only defaults to true, so a
		# stress load on its own fires nothing that is allowed to kick the
		# camera. A player who wanted weight would build one; so does this.
		var arty: BuildOption = null
		for opt in _scene.options:
			var sp: Variant = _scene.call("spec_for", opt)
			for w in sp.weapons:
				if float(w.splash_m) > 0.0 and arty == null:
					arty = opt
		if arty != null:
			var sp2: Variant = _scene.call("spec_for", arty)
			_scene.mass.gain(sp2.mass * 2.0)
			for k in 2:
				_scene.call("_field", arty, sp2,
					_scene.module_pos + Vector2(6.0 + 3.0 * k, -5.0))
				_scene.mass.spend(sp2.mass)
			print("  %5.1fs  built 2x %s (splash) so the shake has a source"
				% [_t, arty.display_name if "display_name" in arty else "artillery"])
		else:
			print("  %5.1fs  NO SPLASH WEAPON in the catalogue — shake cannot fire"
				% _t)

		# And give the drone a job, which is the only thing that turns its
		# scan light on.
		var job: int = _scene.call("_job_near", _scene.module_pos, 40.0)
		if job >= 0:
			_scene.drone_target = job
			_scene.drone_state = "outbound"
			print("  %5.1fs  drone ordered to job %d" % [_t, job])
		else:
			print("  %5.1fs  no job within 40 m for the drone" % _t)
	if _frames == 24 and _scene.has_method("cycle_zoom"):
		_scene.call("cycle_zoom")
		print("  %5.1fs  zoom -> rung %d" % [_t, _scene.zoom_step])
	if _frames == 150:
		_scene.call("_spawn_hostiles", 24, 2.5)
		print("  %5.1fs  second wave" % _t)
	if _frames == 260 and _scene.has_method("cycle_zoom"):
		_scene.call("cycle_zoom")
		print("  %5.1fs  zoom -> rung %d" % [_t, _scene.zoom_step])
	if _frames == 300:
		_scene.call("_spawn_hostiles", 24, 3.0)
		# Walk back the other way, so the leash is exercised in both
		# directions rather than only trailing.
		_scene.module_goal = _scene.module_pos + Vector2(-22.0, -10.0)
		print("  %5.1fs  ordered the module back to %+.0f,%+.0f"
			% [_t, _scene.module_goal.x, _scene.module_goal.y])

	_shots_fired = maxi(_shots_fired, _scene.shots.size())
	_peak_shake = maxf(_peak_shake, _scene._shake)

	if _t >= _next_grab:
		_next_grab += _every
		_grab()

	if _t >= _seconds:
		_finish()
		return true
	return false


func _grab() -> void:
	var img := root.get_texture().get_image()
	if img == null:
		push_error("no viewport image — this needs a real rasteriser")
		return
	var n := _grabs.size()
	var path := OUT_DIR + "/f%02d.png" % n
	img.save_png(path)
	_grabs.append(path)

	var m: Vector2 = _scene.module_pos
	var walked := m.distance_to(_last_module)
	_last_module = m
	var cam := Vector2(_scene.rig.position.x, _scene.rig.position.z)
	var lag := cam.distance_to(m)
	var live := 0
	for a in _scene.aliens:
		if float(a.get("dying", -1.0)) < 0.0:
			live += 1
	_log.append({
		"t": _t, "walked": walked, "lag": lag, "shots": _scene.shots.size(),
		"live": live, "shake": _scene._shake, "drone": _scene.drone_state,
		"zoom": _scene.zoom_step,
	})
	print("  %5.1fs  module %+6.1f,%+6.1f  walked %4.2f m  cam lag %5.1f m"
		% [_t, m.x, m.y, walked, lag]
		+ "  shots %2d  hostiles %2d  shake %.3f  drone %s"
		% [_scene.shots.size(), live, _scene._shake, _scene.drone_state])


## Open the fog so the frames show the map rather than a sheet of haze.
func _reveal() -> void:
	var white := ImageTexture.create_from_image(
		Image.create_empty(1, 1, false, Image.FORMAT_L8))
	var img := Image.create_empty(1, 1, false, Image.FORMAT_L8)
	img.fill(Color.WHITE)
	white.update(img)
	_paint_fog(root, white)


func _paint_fog(n: Node, white: Texture2D) -> void:
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		var mat: Material = mi.material_override
		if mat == null and mi.mesh != null:
			mat = mi.get_active_material(0)
		if mat is ShaderMaterial:
			var sm := mat as ShaderMaterial
			if sm.shader != null:
				for p in sm.shader.get_shader_uniform_list():
					if String(p.name) == "fog_map":
						sm.set_shader_parameter("fog_map", white)
	for c in n.get_children():
		_paint_fog(c, white)


func _finish() -> void:
	print("\n  %d frames rendered, %d captured, %.1f fps average"
		% [_frames, _grabs.size(), float(_frames) / maxf(0.001, _t)])
	var total := 0.0
	var worst_lag := 0.0
	for e in _log:
		total += float(e["walked"])
		worst_lag = maxf(worst_lag, float(e["lag"]))
	print("  module travelled %.1f m over %.0f s (%.2f m/s average)"
		% [total, _t, total / maxf(0.001, _t)])
	print("  camera never lagged more than %.1f m behind it" % worst_lag)
	print("  most shots in the air at once: %d" % _shots_fired)
	print("  hardest camera shake: %.3f m" % _peak_shake)
	print("\n  frames in %s" % OUT_DIR)
	quit()
