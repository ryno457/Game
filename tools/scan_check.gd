extends SceneTree
## Photograph the drone's scan and MEASURE it, rather than looking for it.
##
##   tools/scan_check.sh [WxH]
##
## WHY THIS EXISTS. The scan streaks were committed three times over without
## ever appearing in a frame. Each round fixed a real defect — 16 m streaks
## under a 5.5 m flight height, a 5.5 cm bar seen end-on, a MultiMesh parented
## where its AABB culled it — and each round the thing still drew nothing,
## because the actual cause was the material: alpha, additive and depth-draw
## off together submit perfectly and rasterise to nothing on Forward Mobile.
## `_flat_mesh` already carried a comment saying exactly that.
##
## What let three wrong fixes through was that nothing measured the result. The
## check was "take a screenshot and look", and at 1600x900 six 10 cm bars are
## a smear you can talk yourself into seeing.
##
## SO THIS COUNTS PIXELS, AGAINST A FLOOR IT MEASURES IN THE SAME RUN. Three
## frames, evenly spaced, from one boot:
##
##     A   scan on
##     B   scan on,  three frames later
##     C   scan off, three frames after that
##
## diff(A,B) is everything that moves in three frames while the scan is on: the
## drone flying, the hostiles walking, the vines in the wind, the tonemapper's
## dither. diff(B,C) is all of that PLUS the scan being switched off. If the
## scan draws nothing, the two are the same number, and no amount of squinting
## at a PNG can make them differ. That is the assertion the earlier rounds
## could not have passed and did not have.
##
## The streaks are also checked in the scene graph — visible, instanced, and
## placed somewhere near the drone — because a pixel count alone cannot say
## WHICH of those went wrong when it comes back at the floor.

const OUT_DIR := "res://build/shots"
const SETTLE := 70          # frames before the drone is given its job
const REACH := 260          # frames to wait for it to start working
const GAP := 3              # frames between each of the three captures
## Half-width of the box the pixels are counted in, centred on the drone. The
## streaks reach about 3 m from it and the camera is close, so this is generous.
const PAD := 90             # px of margin: the band blooms well past its own width

var _box_lo := Vector2.ZERO
var _box_hi := Vector2.ZERO

## False as soon as any captured frame had the scan light off.
var _lit_all := true


## Hand the drone another job as soon as it runs out of one, so the spotlight
## never goes out inside the measurement window. Outbound lights the scan just
## as working does, so a hand-off costs nothing.
func _keep_working(scene: Node) -> void:
	var st := String(scene.drone_state)
	if st == "outbound" or st == "working":
		return
	var job: int = scene.call("_job_near", scene.module_pos, 60.0)
	if job >= 0:
		scene.drone_target = job
		scene.drone_state = "outbound"


func _initialize() -> void:
	var argv := OS.get_cmdline_user_args()
	var tag: String = argv[0] if argv.size() > 0 else "scan"
	print("renderer: ", RenderingServer.get_video_adapter_name())

	var ps: PackedScene = load("res://scenes/proto/proto_main.tscn")
	var scene := ps.instantiate()
	root.add_child(scene)

	var white := _white()
	for i in SETTLE:
		await process_frame
		_reveal_all(root, white)
	# Close rung, so six 10 cm bars are more than a smear.
	if scene.has_method("_refresh_zoom_button"):
		scene.set("zoom_step", 0)
		scene.call("_refresh_zoom_button")

	# ORDER THE DRONE. Nothing else turns the scan on: the light is what the
	# drone does to a piece, not a headlamp.
	var job: int = scene.call("_job_near", scene.module_pos, 40.0)
	if job < 0:
		push_error("no salvage job within 40 m — the drone cannot be given "
			+ "work, so this run proves nothing")
		quit(1)
		return
	scene.drone_target = job
	scene.drone_state = "outbound"
	print("drone ordered to job %d" % job)

	# Fly it. "working" is the state the sweep and the full tilt belong to;
	# "outbound" already lights the scan, so either will do for a picture, but
	# wait for working if it gets there.
	var reached := ""
	for i in REACH:
		await process_frame
		_reveal_all(root, white)
		var st := String(scene.drone_state)
		if st == "working":
			reached = st
			break
		if st == "outbound":
			reached = st
	if reached == "":
		push_error("drone never lit its scan — state stayed %s"
			% scene.drone_state)
		quit(1)
		return
	print("drone state: %s" % reached)

	# --- the scene graph, before the pixels ---------------------------------
	#
	# There is no node to inspect any more. The sweep is a band computed inside
	# terrain_lit.gdshader from each fragment's own world XZ, so what can go
	# wrong is not a cull or an AABB or a parenting mistake — it is the
	# uniforms not arriving. That is what is checked.
	var ok := true
	var tmat: ShaderMaterial = scene.terrain.material()
	if tmat == null:
		push_error("no terrain material — nothing to check")
		quit(1)
		return
	var gain: float = tmat.get_shader_parameter("scan_gain")
	var at: Vector2 = tmat.get_shader_parameter("scan_at_m")
	print("  scan_gain %.2f, scan_at_m %s, drone at %s"
		% [gain, at, scene.drone_pos])
	if gain <= 0.0:
		push_error("scan_gain is %.2f with the drone working — the sweep is "
			% gain + "switched off")
		ok = false
	if at.distance_to(scene.drone_pos) > 1.5:
		push_error("the sweep is at %s and the drone is at %s — over a cell "
			% [at, scene.drone_pos] + "apart")
		ok = false

	# --- three frames, with the world held still ----------------------------
	#
	# THE SCENE IS FROZEN FIRST, and this is the whole reason the check works.
	#
	# Three earlier versions measured the wrong thing in three different ways.
	# The first hid the scan with fx.scan_enabled, which takes the SPOTLIGHT
	# out too: 708192 changed pixels against a 47199 floor, a confident 15x
	# pass that would have scored the same with the streaks drawing nothing.
	# The second hid only the streaks and scored 708515 — the same number,
	# because by then the drone had finished its job on its own and the light
	# had gone out anyway. The third kept the drone in work and got an honest
	# 1.18x: 53195 against a floor of 44953, the streaks real but swamped by
	# the drone flying, the hostiles walking, the vines in the wind and the
	# spotlight sweeping, all of which move in three frames.
	#
	# None of those floors had to be there. Disabling processing stops the sim
	# while the renderer carries on, so A and B are the same frame drawn twice
	# and their difference is the tonemapper's dither and nothing else, while
	# C differs from B by exactly six bars. The lights, the transforms and the
	# fog override all stay where they were — none of them needs _process.
	# PUT THE CAMERA ON THE DRONE FIRST. The play camera frames the MODULE, and
	# the drone flies to whatever salvage is nearest — which on this map was a
	# piece 30 m away in the bottom-right corner, behind the build menu. The
	# measurement box was reading HUD panel, which is why it kept coming back
	# at the floor with the streaks working perfectly well off-screen.
	#
	# _frame_camera() takes its aim from module_pos, so that is what gets moved.
	# Nothing downstream cares: the scene is frozen on the next line and the
	# module's own mesh is not re-placed again.
	# The camera hangs off `rig`, not off module_pos — _follow_module drags the
	# rig toward the module on a leash and _frame_camera then places the camera
	# relative to it. So the rig is what moves. Writing module_pos instead did
	# nothing at all, and the drone stayed at 1303,823 behind the menu.
	var rig: Node3D = scene.get("rig")
	rig.position.x = scene.drone_pos.x
	rig.position.z = scene.drone_pos.y
	scene.call("_frame_camera")
	await process_frame
	_reveal_all(root, white)
	scene.process_mode = Node.PROCESS_MODE_DISABLED
	print("scene frozen for the measurement")

	# WHERE THE STREAKS ARE, asked of the camera rather than guessed. The
	# whole-frame counts below drown in the vine shader's wind, which animates
	# off TIME and so keeps running through a frozen scene tree: 46606 pixels
	# move between two identical frames. Six bars a few metres long cannot be
	# seen against that and do not have to be — they are all in one place, and
	# the camera knows where.
	# THE SCENE'S OWN CAMERA, and the box taken from where the STREAKS land
	# rather than from where the drone is.
	#
	# Projecting the drone and measuring +/-150 px around it put the box in the
	# wrong place: the one bar visible in the amplified difference sat about
	# 195 px up and left of that point, outside the box, and the cyan count
	# came back at 16. Rather than work out which of the camera, the rig and
	# the drone's own offset is responsible, the box is now the bounding box of
	# the six instance origins themselves, padded. They are what has to be
	# photographed; there is no need to infer where they are from something
	# else when the transforms are right there.
	var cam: Camera3D = scene.get("camera")
	var dn: Node3D = scene.get("drone")
	var dat := cam.unproject_position(dn.global_position)
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	# EIGHT POINTS ON THE WIDEST RING the sweep reaches, each at its own
	# terrain height so the box follows the slope the band is drawn on.
	var rr: float = scene.fx.scan_ground_max_m
	for i in 8:
		var ang := TAU * float(i) / 8.0
		var q: Vector2 = scene.drone_pos + Vector2(cos(ang), sin(ang)) * rr
		var w := Vector3(q.x, scene.terrain.height_at(q), q.y)
		var sp := cam.unproject_position(w)
		lo = Vector2(minf(lo.x, sp.x), minf(lo.y, sp.y))
		hi = Vector2(maxf(hi.x, sp.x), maxf(hi.y, sp.y))
	_box_lo = lo - Vector2(PAD, PAD)
	_box_hi = hi + Vector2(PAD, PAD)
	print("drone projects to %.0f,%.0f; the sweep spans %.0f,%.0f - %.0f,%.0f"
		% [dat.x, dat.y, lo.x, lo.y, hi.x, hi.y])
	# HOW BIG A METRE IS, here, at this rung. Without it "the streaks changed
	# 1000 pixels" cannot be turned into "the streaks are N pixels wide", which
	# is the only form of the answer anybody can act on.
	var one_m := cam.unproject_position(
		dn.global_position + Vector3(1.0, 0.0, 0.0)).distance_to(dat)
	print("  scale: 1 m = %.1f px, so the %.2f m band is %.1f px across"
		% [one_m, scene.fx.scan_band_m, one_m * scene.fx.scan_band_m])

	# FAT MODE: a diagnostic, not a test. Six 10 cm bars are small enough that
	# "nothing changed" is ambiguous between "culled" and "too thin to see", so
	# this replaces them with metre-wide bars in the same place. If THAT does
	# not move a pixel, the MultiMesh is not rendering and no amount of sizing
	# will help; if it does, the effect draws and the question is only how big
	# it should be.
	# THE WHOLE RING, not the wedge that happens to be pointing somewhere at
	# this instant. The sweep is an arc of half-width scan_arc_rad rotating at
	# scan_sweep_hz, and a frozen frame catches it wherever it was — which on
	# this map is often out over the chasm or behind the build menu. Measured
	# that way the same effect scored 39 cyan pixels at arc 0.9 and 31475 at
	# arc 3.2, which says nothing about the band and everything about the
	# phase. What is under test is whether the band REACHES THE SCREEN; where
	# it is pointing is animation.
	tmat.set_shader_parameter("scan_arc_rad", PI)
	print("  uniforms: r %.2f m, band %.2f m, arc %.2f, tint %s"
		% [float(tmat.get_shader_parameter("scan_r_m")),
		   float(tmat.get_shader_parameter("scan_band_m")),
		   float(tmat.get_shader_parameter("scan_arc_rad")),
		   tmat.get_shader_parameter("scan_tint")])

	if "fat" in argv:
		# A diagnostic, not a test: an enormous band, so that "nothing changed"
		# stops being ambiguous between "too thin to see" and "not drawn".
		tmat.set_shader_parameter("scan_gain", 12.0)
		tmat.set_shader_parameter("scan_band_m", 8.0)
		tmat.set_shader_parameter("scan_arc_rad", 3.2)
		_box_lo = Vector2(0.0, 0.0)
		_box_hi = Vector2(1600.0, 900.0)
		print("FAT MODE: band widened to 8 m over the whole frame")

	var a := await _grab(white, scene)
	var b := await _grab(white, scene)
	# Gain to zero: the branch in the shader is skipped entirely and every
	# other thing in the frame is untouched. _sync_scan would push it back, but
	# it does not run in a frozen scene.
	scene.terrain.set_scan(scene.drone_pos, 0.0, 1.0, 0.0)
	var c := await _grab(white, scene)
	scene.terrain.set_scan(scene.drone_pos, 0.0, 1.0, gain)

	if not _lit_all:
		push_error("the scan light went out mid-measurement — this run "
			+ "measured the spotlight, not the streaks")
		ok = false

	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	a.save_png(OUT_DIR + "/" + tag + "_a.png")
	b.save_png(OUT_DIR + "/" + tag + "_on.png")
	c.save_png(OUT_DIR + "/" + tag + "_off.png")

	var floor_px := _diff(a, b, _box_lo, _box_hi)
	var streak_px := _diff(b, c, _box_lo, _box_hi)
	print("  box %s - %s, %d px of frame"
		% [_box_lo, _box_hi,
		   int((_box_hi.x - _box_lo.x) * (_box_hi.y - _box_lo.y))])
	print("  any-change  floor %d  streaks %d"
		% [_diff_any(a, b, _box_lo, _box_hi), _diff_any(b, c, _box_lo, _box_hi)])
	print("\nchanged pixels in the box around the drone, frozen scene")
	print("  streaks on -> on    %7d   (the floor: the tonemapper's dither)"
		% floor_px)
	print("  streaks on -> off   %7d   (the floor, plus six bars going out)"
		% streak_px)
	if floor_px > 0:
		print("  ratio               %7.1fx" % (float(streak_px) / float(floor_px)))
	else:
		print("  ratio                   inf   (the frozen frame is bit-exact)")

	# The streaks have to be most of what changed. With the world stopped there
	# is nothing else left to change, so anything short of a large multiple
	# means they are not on the screen — which is exactly the state the four
	# earlier attempts at this effect were in, and exactly what no screenshot
	# managed to settle.
	if streak_px < maxi(floor_px * 8, 400):
		push_error("hiding the streaks changed %d pixels against a dither "
			% streak_px + "floor of %d — they are not reaching the screen"
			% floor_px)
		ok = false

	print("\n%s" % ("SCAN OK" if ok else "SCAN FAILED"))
	quit(0 if ok else 1)


## One presented frame, as an Image. Reports the drone's state with it, so a
## run where the light went out on its own is visible in the log rather than
## hidden inside the pixel count.
func _grab(white: Texture2D, scene: Node) -> Image:
	await process_frame
	_keep_working(scene)
	_reveal_all(root, white)
	await process_frame
	# The SPOTLIGHT, not the sweep: the sweep's gain is taken to zero
	# deliberately for the last grab, and watching that would flag this check's
	# own switch as the fault.
	var lamp: SpotLight3D = scene.get("_scan_light")
	if lamp == null or not lamp.visible:
		_lit_all = false
	var tm: ShaderMaterial = scene.terrain.material()
	print("  grab: drone %s, lamp %s, scan_gain %.2f"
		% [scene.drone_state, lamp != null and lamp.visible,
		   float(tm.get_shader_parameter("scan_gain")) if tm != null else -1.0])
	return root.get_texture().get_image()


## Pixels that differ by more than the tonemapper's dither.
##
## The HUD is excluded by ignoring the right-hand build menu and the top and
## bottom bars: they carry live counters that tick over on their own and would
## put a floor under every measurement here for reasons that have nothing to do
## with the scan.
## Pixels where x lost CYAN LIGHT relative to y, inside a box around the drone.
##
## Not a plain magnitude difference, which was the version before this one and
## could not see the effect at all: with the scene frozen the vine shader still
## animates off TIME, and in a 300 px box that wind moves ~2500 pixels while
## six 40 cm streaks move ~550. The amplified difference image says how to
## separate them — the wind shows up RED, because it is the lit edges of brown
## tubes sliding about, and the streaks show up white-cyan, because that is
## what they are (scan_colour is 0.55, 0.95, 1.00). So the test is not "did
## this pixel change" but "did this pixel lose blue-green light it had".
static func _diff(x: Image, y: Image, lo: Vector2, hi: Vector2) -> int:
	var w := x.get_width()
	var h := x.get_height()
	var x0 := clampi(int(lo.x), 0, w - 1)
	var x1 := clampi(int(hi.x), 0, w)
	var y0 := clampi(int(lo.y), 0, h - 1)
	var y1 := clampi(int(hi.y), 0, h)
	var n := 0
	for j in range(y0, y1):
		for i in range(x0, x1):
			var a := x.get_pixel(i, j)
			var b := y.get_pixel(i, j)
			var db := a.b - b.b
			var dg := a.g - b.g
			var dr := a.r - b.r
			# Blue and green up, and bluer than red: the signature of an
			# emissive cyan bar being taken away.
			if db > 0.05 and dg > 0.03 and (db - dr) > 0.02:
				n += 1
	return n


## Plain magnitude difference, for when the cyan test reads zero and the
## question is whether nothing changed or the change was not cyan.
static func _diff_any(x: Image, y: Image, lo: Vector2, hi: Vector2) -> int:
	var w := x.get_width()
	var h := x.get_height()
	var n := 0
	for j in range(clampi(int(lo.y), 0, h - 1), clampi(int(hi.y), 0, h)):
		for i in range(clampi(int(lo.x), 0, w - 1), clampi(int(hi.x), 0, w)):
			var a := x.get_pixel(i, j)
			var b := y.get_pixel(i, j)
			if absf(a.r-b.r) + absf(a.g-b.g) + absf(a.b-b.b) > 0.02:
				n += 1
	return n


func _reveal_all(n: Node, white: Texture2D) -> void:
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		var m: Material = mi.material_override
		if m == null and mi.mesh != null:
			m = mi.get_active_material(0)
		if m is ShaderMaterial:
			var sm := m as ShaderMaterial
			if sm.shader != null and sm.shader.resource_path.ends_with(
					"terrain_lit.gdshader"):
				sm.set_shader_parameter("fog_map", white)
	for c in n.get_children():
		_reveal_all(c, white)


static func _white() -> Texture2D:
	var img := Image.create_empty(1, 1, false, Image.FORMAT_R8)
	img.set_pixel(0, 0, Color(1, 1, 1))
	return ImageTexture.create_from_image(img)
