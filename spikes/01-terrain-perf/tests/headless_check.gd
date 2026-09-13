extends SceneTree
## Headless validation of the spike's data layer.
##
## The device will hand back a frame-time number. This exists so that number
## means something: if the field, the dirty tracking or the collision export
## were wrong, the spike would be measuring the cost of doing the wrong thing
## quickly. Run: godot --headless --path . --script tests/headless_check.gd

const CELLS := Vector2i(160, 128)
const CHUNK := 32
const NEUTRAL := 0.50
const IMPASSABLE := 0.26
const ROUGH := 0.38
const HEIGHT_SCALE := 12.0
const DIG_RATE := -1.5
const DIG_RADIUS := 1.6

var _failed := 0


func _initialize() -> void:
	print("SPIKE A — headless data-layer check\n")
	_check_excavator_breaches_threshold()
	_check_gradient_passes_through_rough()
	_check_scar_floor_cannot_trap_units()
	_check_collision_export_matches_field()
	_check_seam_neighbours_go_dirty()
	_check_dig_is_frame_rate_independent()
	_check_verdict_and_log_round_trip()
	print("")
	if _failed == 0:
		print("ALL CHECKS PASSED — the spike is measuring the right thing.")
	else:
		print("%d CHECK(S) FAILED" % _failed)
	quit(1 if _failed > 0 else 0)


func _ok(name: String, cond: bool, detail: String) -> void:
	if cond:
		print("  PASS  %s  %s" % [name.rpad(42), detail])
	else:
		_failed += 1
		print("  FAIL  %s  %s" % [name.rpad(42), detail])


func _field() -> DeformField:
	return DeformField.new(CELLS, CHUNK, 1.0, HEIGHT_SCALE, NEUTRAL, 20260913)


## THE question this spike sits on top of. If the tuned dig rate cannot cut
## below the impassable threshold, trenches are cosmetic and the design
## changes — regardless of what the frame counter says.
func _check_excavator_breaches_threshold() -> void:
	var f := _field()
	var p := Vector2(80.0, 64.0)
	var step := 1.0 / 60.0
	var t := 0.0
	while t < 5.0:
		f.deform(p, DIG_RADIUS, DIG_RATE * step)
		t += step
		if not f.is_passable(p, IMPASSABLE):
			break
	_ok("excavator breaches impassable", not f.is_passable(p, IMPASSABLE),
		"severed after %.2fs of digging (h=%.3f)" % [t, f.height_at(p)])
	_ok("and it feels deliberate, not glacial", t < 1.0, "%.2fs < 1.00s" % t)


## A trench must read as a gradient the player can see coming — ground slows
## before it severs. Worldgen noise means no probe point starts at exactly
## neutral, so dig incrementally and watch for the rough band rather than
## assuming a fixed starting height.
func _check_gradient_passes_through_rough() -> void:
	var f := _field()
	var p := Vector2(40.0, 40.0)
	var start := f.height_at(p)
	var step := 1.0 / 60.0
	var rough_frames := 0
	var t := 0.0
	while t < 5.0 and f.is_passable(p, IMPASSABLE):
		f.deform(p, DIG_RADIUS, DIG_RATE * step)
		t += step
		var h := f.height_at(p)
		if h < ROUGH and h > IMPASSABLE:
			rough_frames += 1
	_ok("ground slows before it severs", rough_frames > 0,
		"start %.3f, %d frames (%.2fs) in the rough band before severing" % [
			start, rough_frames, rough_frames * step])


## A long firefight in one place must never dig its own moat.
func _check_scar_floor_cannot_trap_units() -> void:
	var f := _field()
	var p := Vector2(100.0, 40.0)
	for i in 2000:
		f.deform(p, 1.0, -0.011, ROUGH)
	_ok("weapon scarring floors at rough", f.is_passable(p, IMPASSABLE),
		"h=%.3f after 2000 hits (floor %.2f)" % [f.height_at(p), ROUGH])


## Collision is the CPU-side truth the raycast and the units read. If it
## disagrees with the field, digging lands in the wrong place.
func _check_collision_export_matches_field() -> void:
	var f := _field()
	f.deform(Vector2(48.0, 48.0), 6.0, -0.3)
	var n := CHUNK + 1
	var data := f.chunk_collision_data(1, 1)
	_ok("collision shape size", data.size() == n * n,
		"%d samples == (%d)^2" % [data.size(), n])

	var worst := 0.0
	for z in n:
		for x in n:
			var expect: float = f.heights[f.index(CHUNK + x, CHUNK + z)] * HEIGHT_SCALE
			worst = maxf(worst, absf(data[z * n + x] - expect))
	_ok("collision heights match field", worst < 0.0001,
		"max divergence %.6f m" % worst)

	# Seam sharing: chunk (0,0)'s last column must equal chunk (1,0)'s first.
	var a := f.chunk_collision_data(0, 0)
	var b := f.chunk_collision_data(1, 0)
	var seam_ok := true
	for z in n:
		if absf(a[z * n + (n - 1)] - b[z * n]) > 0.0001:
			seam_ok = false
			break
	_ok("chunk seams share vertices", seam_ok, "no cracks between (0,0) and (1,0)")


func _check_seam_neighbours_go_dirty() -> void:
	var f := _field()
	f.dirty.clear()
	# Dig exactly on the boundary between chunk 0 and chunk 1.
	f.deform(Vector2(float(CHUNK), 48.0), DIG_RADIUS, -0.2)
	_ok("seam dig dirties both chunks",
		f.dirty.has(Vector2i(0, 1)) and f.dirty.has(Vector2i(1, 1)),
		"dirty = %s" % [f.dirty.keys()])


## The prototype's flatten() was per-frame, not per-second. The spike's dig
## must not repeat that mistake, or every measurement is framerate-relative.
func _check_dig_is_frame_rate_independent() -> void:
	var slow := _field()
	var fast := _field()
	var p := Vector2(64.0, 64.0)
	for i in 30:
		slow.deform(p, DIG_RADIUS, DIG_RATE * (1.0 / 30.0))
	for i in 120:
		fast.deform(p, DIG_RADIUS, DIG_RATE * (1.0 / 120.0))
	var d := absf(slow.height_at(p) - fast.height_at(p))
	_ok("dig rate is frame-rate independent", d < 0.001,
		"30fps vs 120fps diverge by %.5f" % d)


## The CSV IS the deliverable of this spike. Verify the whole reporting path —
## bucketing, verdict, file write — rather than discovering it is broken after
## a ten-minute soak on a phone.
func _check_verdict_and_log_round_trip() -> void:
	var terrain := SpikeTerrain.new()
	var swarm := UnitSwarm.new()
	var probe := SpikeProbe.new()

	# Two clean minutes at a steady 60fps: every criterion should pass.
	probe.start()
	for i in 7300:
		probe.sample(1.0 / 60.0, terrain, swarm)
	var good := probe.verdict()
	_ok("steady 60fps verdicts PASS", good.passed,
		"%d minute buckets, p95 %.2f ms" % [probe.buckets.size(), good.p95])

	# Now a run that spends its second minute at 30fps: thermal drift must bite.
	probe.start()
	for i in 3650:
		probe.sample(1.0 / 60.0, terrain, swarm)
	for i in 1825:
		probe.sample(1.0 / 30.0, terrain, swarm)
	var bad := probe.verdict()
	_ok("thermal throttle verdicts FAIL", not bad.passed,
		"caught: %s" % bad.lines[2])

	var path := probe.write_log(bad, "headless-check")
	var f := FileAccess.open(path, FileAccess.READ)
	var text := f.get_as_text() if f != null else ""
	if f != null:
		f.close()
	_ok("log writes and reads back",
		text.contains("# verdict: FAIL") and text.contains("t_s,fps,"),
		"%d bytes at %s" % [text.length(), path])

	terrain.free()
	swarm.free()
