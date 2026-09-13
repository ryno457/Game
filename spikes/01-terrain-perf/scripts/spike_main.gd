extends Node3D
## SPIKE A — does a deformable heightfield hold 60fps on a mid-range phone?
##
## Run it, press SOAK, put the phone down for ten minutes, read the verdict.
## There is no gameplay here and there should never be any.

const CELLS := Vector2i(160, 128)     ## 22% more cells than the real 150x112 — deliberately conservative
const CHUNK_CELLS := 32               ## 5 x 4 = 20 chunks
const CELL_SIZE := 1.0                ## HeightMapShape3D assumes 1-unit spacing
const HEIGHT_SCALE := 12.0
const NEUTRAL := 0.50
const IMPASSABLE_BELOW := 0.26
const SEED := 20260913

const DIG_RADIUS := 1.6
const DIG_RATE := -1.5                ## per second, matches the tuned prototype value
const AUTO_DIG_SPEED := 14.0          ## m/s for the scripted soak digger

@onready var terrain: SpikeTerrain = $Terrain
@onready var swarm: UnitSwarm = $Swarm
@onready var camera: Camera3D = $CameraRig/Camera3D
@onready var rig: Node3D = $CameraRig
@onready var readout: Label = $HUD/Panel/Readout
@onready var verdict_label: Label = $HUD/Panel/Verdict
@onready var soak_button: Button = $HUD/Controls/Soak
@onready var units_button: Button = $HUD/Controls/Units
@onready var mode_button: Button = $HUD/Controls/Mode

var field: DeformField
var probe := SpikeProbe.new()

var _pan_mode := false
var _dragging := false
var _dirty_this_frame := false
var _auto := false
var _auto_t := 0.0
var _device := ""
var _log_path := ""
var _unit_steps := [150, 300, 600, 0]
var _unit_step := 0


func _ready() -> void:
	_device = "%s / %s / %s" % [
		OS.get_name(), OS.get_model_name(),
		RenderingServer.get_video_adapter_name()]

	field = DeformField.new(CELLS, CHUNK_CELLS, CELL_SIZE, HEIGHT_SCALE, NEUTRAL, SEED)
	terrain.impassable_below = IMPASSABLE_BELOW
	terrain.setup(field, load("res://shaders/terrain.gdshader"))
	swarm.impassable_below = IMPASSABLE_BELOW
	swarm.setup(field, _unit_steps[_unit_step], SEED)

	var e := field.extent_m()
	rig.position = Vector3(e.x * 0.5, 0.0, e.y * 0.5)
	_frame_camera()

	soak_button.pressed.connect(_toggle_soak)
	units_button.pressed.connect(_cycle_units)
	mode_button.pressed.connect(_toggle_mode)
	_refresh_buttons()

	# `godot --path . -- --soak` starts the run without a tap, so a device
	# soak can be kicked off over adb and so this scene is smoke-testable.
	if "--soak" in OS.get_cmdline_user_args():
		_toggle_soak()


func _frame_camera() -> void:
	# A plausible RTS framing for a phone: pitched enough to read relief,
	# high enough to see a useful slice of the field.
	camera.position = Vector3(0.0, 46.0, 38.0)
	camera.look_at(rig.global_position, Vector3.UP)
	camera.fov = 60.0


func _process(delta: float) -> void:
	_dirty_this_frame = false

	if _auto:
		_auto_dig(delta)

	swarm.update(delta)
	terrain.flush(_dirty_this_frame or not field.dirty.is_empty())
	probe.sample(delta, terrain, swarm)

	if probe.running:
		_refresh_readout()
	elif not probe.rows.is_empty() and verdict_label.text == "":
		_publish_verdict()


## Scripted digger so a ten-minute soak is unattended and reproducible. It
## carves a serpentine across the field, then raises it back, so the terrain
## never settles into a state where nothing more needs re-cooking.
func _auto_dig(delta: float) -> void:
	_auto_t += delta
	var e := field.extent_m()
	var phase := fmod(_auto_t * AUTO_DIG_SPEED / e.x, 2.0)
	var sweep := absf(phase - 1.0)
	var p := Vector2(
		e.x * sweep,
		e.y * (0.15 + 0.7 * (0.5 + 0.5 * sin(_auto_t * 0.21))))
	# Second head digging elsewhere, so more than one chunk is dirty per frame.
	var q := Vector2(e.x - p.x, e.y - p.y)
	var amount := DIG_RATE * delta
	if fmod(_auto_t, 40.0) > 20.0:
		amount = -amount * 0.8        # fill back in
	field.deform(p, DIG_RADIUS, amount)
	field.deform(q, DIG_RADIUS * 1.4, amount * 0.6)
	_dirty_this_frame = true


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_dragging = event.pressed
		if event.pressed and not _pan_mode:
			_dig_at(event.position, 1.0 / 60.0)
	elif event is InputEventScreenDrag:
		if _pan_mode:
			rig.position += Vector3(-event.relative.x, 0.0, -event.relative.y) * 0.12
		else:
			_dig_at(event.position, 1.0 / 60.0)


func _dig_at(screen: Vector2, dt: float) -> void:
	var hit := _raycast_terrain(screen)
	if hit.is_empty():
		return
	var p: Vector3 = hit["position"]
	field.deform(Vector2(p.x, p.z), DIG_RADIUS, DIG_RATE * dt * 8.0)
	_dirty_this_frame = true


## Raycast against the collision heightmap — the CPU-side truth. If the shader
## and the collision shapes ever disagree, digging lands in the wrong place,
## and that mismatch is itself a finding worth seeing.
func _raycast_terrain(screen: Vector2) -> Dictionary:
	var from := camera.project_ray_origin(screen)
	var dir := camera.project_ray_normal(screen)
	var params := PhysicsRayQueryParameters3D.create(from, from + dir * 400.0)
	return get_world_3d().direct_space_state.intersect_ray(params)


func _toggle_soak() -> void:
	if probe.running:
		probe.finish()
		_publish_verdict()
	else:
		verdict_label.text = ""
		_log_path = ""
		field.generate()
		terrain.flush(true)
		_auto = true
		probe.start()
	_refresh_buttons()


func _cycle_units() -> void:
	_unit_step = (_unit_step + 1) % _unit_steps.size()
	swarm.set_count(_unit_steps[_unit_step])
	_refresh_buttons()


func _toggle_mode() -> void:
	_pan_mode = not _pan_mode
	_refresh_buttons()


func _refresh_buttons() -> void:
	soak_button.text = "■ STOP SOAK" if probe.running else "▶ SOAK 10 MIN"
	units_button.text = "UNITS %d" % swarm.get_count()
	mode_button.text = "PAN" if _pan_mode else "DIG"


func _refresh_readout() -> void:
	var remain := int(maxf(0.0, SpikeProbe.SOAK_S - probe.elapsed))
	readout.text = "\n".join([
		"SOAK   %d:%02d remaining" % [remain / 60, remain % 60],
		"fps    %.1f" % Engine.get_frames_per_second(),
		"tex    %.2f ms" % terrain.last_texture_ms,
		"coll   %.2f ms   chunks %d   backlog %d" % [
			terrain.last_collision_ms, terrain.last_chunks_rebuilt, terrain.backlog],
		"units  %.2f ms   n %d" % [swarm.last_update_ms, swarm.get_count()],
		"draws  %d" % Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"vram   %.1f MB" % (Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0),
	])


func _publish_verdict() -> void:
	_auto = false
	var v := probe.verdict()
	if _log_path == "":
		_log_path = probe.write_log(v, _device)
	var head := "VERDICT: %s" % ("PASS — build on it" if v.passed else "FAIL — see CLAUDE.md fallback")
	verdict_label.text = "\n".join(
		([head, _device] as Array[String]) + v.lines + ["log: %s" % _log_path])
	_refresh_buttons()
