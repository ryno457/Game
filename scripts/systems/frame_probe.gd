class_name FrameProbe
extends RefCounted
## Frame-time instrumentation for the phone build.
##
## Spike A answered "can deformable terrain hold 60fps" on a Galaxy A54 with
## the terrain UNLIT and UNDRESSED. Since then the map gained a lighting rig,
## an emissive terrain shader and four hundred instanced props, and the honest
## position is that the phone number is unknown again.
##
## THE CRITERIA BELOW ARE FIXED BEFORE THE BUILD EVER RUNS ON A DEVICE. That is
## the whole discipline of a spike: a threshold argued for after seeing the
## number is not a threshold. Spike A already made this mistake once and the
## fix is recorded in docs/spike-a-findings.md.

const TARGET_FRAME_MS := 16.67     ## 60fps
const BUCKET_S := 60.0             ## one verdict row per minute
## Last minute against the first. A phone that starts at 60 and ends at 45 has
## thermally throttled, and a number taken in the first thirty seconds is a
## number taken from a cold device.
const THERMAL_DRIFT_MAX := 1.25
## Below this there is not enough data to say anything. Reporting a verdict off
## twenty seconds of play would be worse than reporting nothing.
const MIN_SOAK_S := 120.0

var elapsed := 0.0
var frames := 0

## Draw calls and primitives are REPORTED, NOT JUDGED. There is no defensible
## budget for them on this device that is not a guess, and inventing one would
## turn a diagnostic into a criterion nobody can argue with.
var draw_calls := 0
var primitives := 0
var video_mb := 0.0

var _all: PackedFloat32Array = PackedFloat32Array()
var _bucket: PackedFloat32Array = PackedFloat32Array()
var _bucket_start := 0.0
var minutes: Array[Dictionary] = []

var _recent: PackedFloat32Array = PackedFloat32Array()
const RECENT := 90                 ## about 1.5 s, for the live readout


func reset() -> void:
	elapsed = 0.0
	frames = 0
	_all = PackedFloat32Array()
	_bucket = PackedFloat32Array()
	_recent = PackedFloat32Array()
	_bucket_start = 0.0
	minutes.clear()


func sample(delta: float) -> void:
	var ms := delta * 1000.0
	elapsed += delta
	frames += 1
	_all.append(ms)
	_bucket.append(ms)
	_recent.append(ms)
	if _recent.size() > RECENT:
		_recent = _recent.slice(_recent.size() - RECENT)

	draw_calls = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	primitives = int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	video_mb = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0

	if elapsed - _bucket_start >= BUCKET_S:
		minutes.append({
			"minute": minutes.size() + 1,
			"mean": _mean(_bucket),
			"p95": _pct(_bucket, 0.95),
			"worst": _max(_bucket),
			"fps": 1000.0 / maxf(0.001, _mean(_bucket)),
		})
		_bucket = PackedFloat32Array()
		_bucket_start = elapsed


# --- live numbers ------------------------------------------------------------
func live_fps() -> float:
	return 1000.0 / maxf(0.001, _mean(_recent))


func live_ms() -> float:
	return _mean(_recent)


func session_p95() -> float:
	return _pct(_all, 0.95)


func session_mean() -> float:
	return _mean(_all)


## Worst full minute seen. The number that decides whether this ships, because
## it is the one the player feels in a long fight on a hot phone.
func worst_minute_ms() -> float:
	var w := 0.0
	for m in minutes:
		w = maxf(w, m.mean)
	return w


## Last minute divided by the first. Above 1.0 means the device is slowing down.
func thermal_drift() -> float:
	if minutes.size() < 2:
		return 1.0
	return minutes[-1].mean / maxf(0.001, minutes[0].mean)


# --- the verdict -------------------------------------------------------------
## Lines for the verdict card, and whether every criterion passed.
func verdict() -> Dictionary:
	var rows: Array[Dictionary] = []
	if elapsed < MIN_SOAK_S:
		return {"ready": false, "pass": false, "rows": rows,
			"note": "play for %d more seconds" % int(MIN_SOAK_S - elapsed)}

	rows.append(_row("p95 frame time", session_p95(), TARGET_FRAME_MS,
		"%.2f ms  (budget %.2f)" % [session_p95(), TARGET_FRAME_MS]))
	rows.append(_row("worst minute", worst_minute_ms(), TARGET_FRAME_MS,
		"%.2f ms mean  (%.1f fps)"
			% [worst_minute_ms(), 1000.0 / maxf(0.001, worst_minute_ms())]))
	rows.append(_row("thermal drift", thermal_drift(), THERMAL_DRIFT_MAX,
		"x%.2f over %d minutes" % [thermal_drift(), minutes.size()]))

	var all_pass := true
	for r in rows:
		all_pass = all_pass and r.pass
	return {"ready": true, "pass": all_pass, "rows": rows, "note": ""}


func _row(name: String, value: float, budget: float, detail: String) -> Dictionary:
	return {"name": name, "pass": value <= budget, "detail": detail}


# --- statistics --------------------------------------------------------------
static func _mean(a: PackedFloat32Array) -> float:
	if a.is_empty():
		return 0.0
	var t := 0.0
	for v in a:
		t += v
	return t / a.size()


static func _max(a: PackedFloat32Array) -> float:
	var m := 0.0
	for v in a:
		m = maxf(m, v)
	return m


static func _pct(a: PackedFloat32Array, p: float) -> float:
	if a.is_empty():
		return 0.0
	var s := a.duplicate()
	s.sort()
	return s[clampi(int(s.size() * p), 0, s.size() - 1)]


## The whole session as CSV, for when a screenshot is not enough.
func csv() -> String:
	var out := "minute,fps,frame_ms_mean,frame_ms_p95,frame_ms_worst\n"
	for m in minutes:
		out += "%d,%.1f,%.3f,%.3f,%.3f\n" % [m.minute, m.fps, m.mean, m.p95, m.worst]
	return out
