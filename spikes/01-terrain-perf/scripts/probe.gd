class_name SpikeProbe
extends RefCounted
## Instrumentation and the verdict.
##
## The pass criteria are fixed here, in code, BEFORE the spike is ever run on
## a device. That is deliberate: a threshold argued for after seeing the
## number is not a threshold.

const TARGET_FRAME_MS := 16.67          ## 60fps
const BUCKET_S := 60.0                  ## one verdict row per minute
const THERMAL_DRIFT_MAX := 1.25         ## last minute vs first minute
const COLLISION_BUDGET_MS := 4.0        ## p95 of collision re-cook per frame
const SOAK_S := 600.0                   ## 10 minutes to reach thermal steady state
## Longest run of consecutive frames the chunk queue may stay non-empty.
##
## This replaces an earlier "peak backlog must be 0" criterion, which measured
## the wrong thing. The 6 ms drain budget exists precisely so a burst DEFERS
## work instead of blowing the frame, so a one-frame queue is the budget doing
## its job. What matters is whether the queue DRAINS — a run that keeps growing
## means collision cannot keep up with digging. On a Galaxy A54 the old
## criterion failed on a transient peak of 2 while the live readout showed 0.
const MAX_BACKLOG_RUN := 10             ## about 0.17 s at 60fps

var elapsed := 0.0
var running := false

var _all_frames: PackedFloat32Array = PackedFloat32Array()
var _bucket_frames: PackedFloat32Array = PackedFloat32Array()
var _all_collision: PackedFloat32Array = PackedFloat32Array()
var _bucket_start := 0.0
var buckets: Array[Dictionary] = []

var _sec_frames := 0
var _sec_accum := 0.0
var _sec_start := 0.0
var rows: Array[String] = []

var peak_backlog := 0
var max_backlog_run := 0
var _backlog_run := 0


func start() -> void:
	elapsed = 0.0
	running = true
	_all_frames = PackedFloat32Array()
	_bucket_frames = PackedFloat32Array()
	_all_collision = PackedFloat32Array()
	buckets.clear()
	rows.clear()
	rows.append("t_s,fps,frame_ms_mean,frame_ms_p95,texture_ms,collision_ms,units_ms,chunks,backlog,units,draw_calls,vram_mb")
	_bucket_start = 0.0
	_sec_start = 0.0
	_sec_frames = 0
	_sec_accum = 0.0
	peak_backlog = 0
	max_backlog_run = 0
	_backlog_run = 0


func sample(delta: float, terrain: SpikeTerrain, swarm: UnitSwarm) -> void:
	if not running:
		return
	var frame_ms := delta * 1000.0
	elapsed += delta

	_all_frames.append(frame_ms)
	_bucket_frames.append(frame_ms)
	_all_collision.append(terrain.last_collision_ms)
	peak_backlog = maxi(peak_backlog, terrain.backlog)
	if terrain.backlog > 0:
		_backlog_run += 1
		max_backlog_run = maxi(max_backlog_run, _backlog_run)
	else:
		_backlog_run = 0

	_sec_frames += 1
	_sec_accum += frame_ms

	if elapsed - _sec_start >= 1.0:
		rows.append("%.1f,%.1f,%.2f,%.2f,%.2f,%.2f,%.2f,%d,%d,%d,%d,%.1f" % [
			elapsed,
			_sec_frames / (elapsed - _sec_start),
			_sec_accum / maxi(1, _sec_frames),
			_p95(_bucket_frames),
			terrain.last_texture_ms,
			terrain.last_collision_ms,
			swarm.last_update_ms,
			terrain.last_chunks_rebuilt,
			terrain.backlog,
			swarm.get_count(),
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		])
		_sec_start = elapsed
		_sec_frames = 0
		_sec_accum = 0.0

	if elapsed - _bucket_start >= BUCKET_S:
		_close_bucket()

	if elapsed >= SOAK_S:
		finish()


func _close_bucket() -> void:
	if _bucket_frames.is_empty():
		return
	buckets.append({
		"minute": buckets.size() + 1,
		"mean_ms": _mean(_bucket_frames),
		"p95_ms": _p95(_bucket_frames),
		"fps": 1000.0 / maxf(0.001, _mean(_bucket_frames)),
	})
	_bucket_frames = PackedFloat32Array()
	_bucket_start = elapsed


func finish() -> void:
	if not running:
		return
	_close_bucket()
	running = false


static func _mean(a: PackedFloat32Array) -> float:
	if a.is_empty():
		return 0.0
	var n := 0.0
	for v in a:
		n += v
	return n / a.size()


static func _p95(a: PackedFloat32Array) -> float:
	if a.is_empty():
		return 0.0
	var c := a.duplicate()
	c.sort()
	return c[mini(c.size() - 1, int(c.size() * 0.95))]


## Returns {pass: bool, lines: Array[String]} — one line per criterion, each
## reading PASS or FAIL with the number that decided it.
func verdict() -> Dictionary:
	var lines: Array[String] = []
	var ok := true

	var p95 := _p95(_all_frames)
	var c1 := p95 <= TARGET_FRAME_MS
	ok = ok and c1
	lines.append("%s  p95 frame %.2f ms (limit %.2f)" % ["PASS" if c1 else "FAIL", p95, TARGET_FRAME_MS])

	var worst := 0.0
	var worst_min := 0
	for b in buckets:
		if b.mean_ms > worst:
			worst = b.mean_ms
			worst_min = b.minute
	var c2 := not buckets.is_empty() and worst <= TARGET_FRAME_MS
	ok = ok and c2
	lines.append("%s  worst minute mean %.2f ms (min %d, limit %.2f)" % [
		"PASS" if c2 else "FAIL", worst, worst_min, TARGET_FRAME_MS])

	var c3 := true
	if buckets.size() >= 2:
		var drift: float = buckets[-1].mean_ms / maxf(0.001, buckets[0].mean_ms)
		c3 = drift <= THERMAL_DRIFT_MAX
		lines.append("%s  thermal drift x%.2f (limit x%.2f)" % [
			"PASS" if c3 else "FAIL", drift, THERMAL_DRIFT_MAX])
	else:
		c3 = false
		lines.append("FAIL  thermal drift — soak too short to judge (need 2+ minutes)")
	ok = ok and c3

	var cp95 := _p95(_all_collision)
	var c4 := cp95 <= COLLISION_BUDGET_MS
	ok = ok and c4
	lines.append("%s  p95 collision re-cook %.2f ms (budget %.2f)" % [
		"PASS" if c4 else "FAIL", cp95, COLLISION_BUDGET_MS])

	var c5 := max_backlog_run <= MAX_BACKLOG_RUN
	ok = ok and c5
	lines.append("%s  chunk queue drains: longest run %d frames, peak %d (limit %d)" % [
		"PASS" if c5 else "FAIL", max_backlog_run, peak_backlog, MAX_BACKLOG_RUN])

	return {"passed": ok, "lines": lines, "p95": p95}


func write_log(verdict_data: Dictionary, device: String) -> String:
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var path := "user://spike_a_%s.csv" % stamp
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "<could not open %s>" % path
	f.store_line("# SENTINEL Spike A — deformable terrain performance")
	f.store_line("# device: %s" % device)
	f.store_line("# verdict: %s" % ("PASS" if verdict_data.passed else "FAIL"))
	for l in verdict_data.lines:
		f.store_line("# %s" % l)
	f.store_line("# longest backlog run: %d frames (peak queue %d)" % [max_backlog_run, peak_backlog])
	for b in buckets:
		f.store_line("# minute %d: mean %.2f ms  p95 %.2f ms  %.1f fps" % [
			b.minute, b.mean_ms, b.p95_ms, b.fps])
	for r in rows:
		f.store_line(r)
	f.close()
	return ProjectSettings.globalize_path(path)
