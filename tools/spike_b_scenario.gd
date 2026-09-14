extends SceneTree
## SPIKE B — does pathfinding react correctly to a FRESHLY DUG U-trench?
##
## Risk item 2. This decides whether trenches are a real defensive tool or a
## decoration, and therefore whether the Burrowing adaptation is a counter or
## just unfair scaling.
##
## Unlike Spike A this is a correctness question, so it runs headlessly and
## deterministically — no device, no eyeballing. Ground is deliberately FLAT:
## the dug trench is the only obstacle, so nothing else can explain a result.
##
##   godot --headless --path . --script tools/spike_b_scenario.gd

const SEED := 20260913
const DT := 1.0 / 60.0
const SIM_LIMIT_S := 60.0
## Units spawn ~52 m out and travel at 4.875 m/s, so the leading rank reaches
## the trench mouth at about t=10.7 s. Digging at 10.0 s drops the trench
## roughly 3 m in front of them — genuinely "freshly dug". An earlier dig lets
## the field settle long before anyone arrives and tests nothing about
## reaction, which is what the first version of this scenario did.
const DIG_AT_S := 10.0
const UNITS := 120
const UNIT_SPEED := 4.875      # Salvage Drone, from prototype-balance.md

# --- pass criteria, fixed before the first run -------------------------------
const MIN_ARRIVAL := 0.95
const MAX_GRIND_FRACTION := 0.02
const MAX_TRAPPED := 0
const MAX_CORNER_CUTS := 0
## A rebuild blocks the frame it runs in. One frame at 60fps is the bar; if it
## cannot meet that it must be amortized or moved off the main thread, and
## saying so is the useful output.
const REBUILD_BUDGET_MS := 16.67

var cfg: TerrainConfig
var _failed := 0
var _lines: Array[String] = []


func _initialize() -> void:
	cfg = load("res://data/terrain/biodome_01.tres")
	print("SPIKE B — flow field vs a freshly dug U-trench\n")

	var walker := _run("walkers", false, false)
	var burrower := _run("burrowers", true, false)
	var uniform := _run("uniform-cost", false, true)
	# 7 frames ~= the measured 109 ms rebuild; 30 frames is a deliberately
	# pessimistic half-second, well past anything a worker thread would cost.
	var lag7 := _run("stale 7f", false, false, 7)
	var lag30 := _run("stale 30f", false, false, 30)

	print("\n--- criteria ---")
	_ok("units reach the goal", walker.arrival >= MIN_ARRIVAL,
		"%.1f%% arrived (need %.0f%%)" % [walker.arrival * 100.0, MIN_ARRIVAL * 100.0])
	_ok("nobody trapped in the pocket", walker.trapped <= MAX_TRAPPED,
		"%d still inside the U at timeout" % walker.trapped)
	_ok("no wall-grinding", walker.grind <= MAX_GRIND_FRACTION,
		"%.2f%% of unit-seconds spent stalled on a wall (limit %.0f%%)" %
		[walker.grind * 100.0, MAX_GRIND_FRACTION * 100.0])
	_ok("no diagonal corner-cutting", walker.cuts <= MAX_CORNER_CUTS,
		"%d units slipped through a 1-cell wall" % walker.cuts)
	_ok("burrowers ignore the trench", burrower.arrival >= MIN_ARRIVAL
			and burrower.mean_path < walker.mean_path,
		"burrow path %.1fm vs walker detour %.1fm (%.0f%% shorter)" %
		[burrower.mean_path, walker.mean_path,
		 (1.0 - burrower.mean_path / maxf(0.001, walker.mean_path)) * 100.0])
	_ok("rebuild fits one frame", walker.rebuild_ms <= REBUILD_BUDGET_MS,
		"%.1f ms full rebuild over %d cells (budget %.2f ms)" %
		[walker.rebuild_ms, walker.visited, REBUILD_BUDGET_MS])

	print("\n--- does a late field update hurt? ---")
	_ok("tolerates a 7-frame stale field", lag7.arrival >= MIN_ARRIVAL
			and lag7.trapped <= MAX_TRAPPED and lag7.grind <= MAX_GRIND_FRACTION,
		"%.0f%% arrived, %d trapped, %.2f%% grinding" %
		[lag7.arrival * 100.0, lag7.trapped, lag7.grind * 100.0])
	_ok("tolerates a 30-frame stale field", lag30.arrival >= MIN_ARRIVAL
			and lag30.trapped <= MAX_TRAPPED and lag30.grind <= MAX_GRIND_FRACTION,
		"%.0f%% arrived, %d trapped, %.2f%% grinding" %
		[lag30.arrival * 100.0, lag30.trapped, lag30.grind * 100.0])

	print("\n--- cost comparison ---")
	print("  weighted (Dijkstra)   %6.1f ms   mean path %.1f m" % [walker.rebuild_ms, walker.mean_path])
	print("  uniform  (BFS-like)   %6.1f ms   mean path %.1f m" % [uniform.rebuild_ms, uniform.mean_path])

	print("")
	for l in _lines:
		print(l)
	print("")
	if _failed == 0:
		print("SPIKE B: PASS — trenches are a real tactic. Burrowing is a genuine counter.")
	else:
		print("SPIKE B: FAIL — %d criterion(s) failed." % _failed)
	quit(1 if _failed > 0 else 0)


func _ok(name: String, cond: bool, detail: String) -> void:
	if not cond:
		_failed += 1
	print("  %s  %s  %s" % ["PASS" if cond else "FAIL", name.rpad(34), detail])


## Carve a U opening TOWARD the incoming units: a back wall they hit head-on
## and two arms that close the sides. A greedy or potential-field steerer walks
## into the mouth and stalls against the back wall; only a true distance field
## routes back out and around.
func _dig_u(hf: Heightfield, mouth_x: float, centre_z: float, depth_m: float,
		half_height: float) -> Rect2:
	var back_x := mouth_x + depth_m
	var r := 1.6
	var step := 1.0
	# back wall
	var z := centre_z - half_height
	while z <= centre_z + half_height:
		hf.deform(Vector2(back_x, z), r, -1.0)
		z += step
	# two arms, running back toward the units
	var x := mouth_x
	while x <= back_x:
		hf.deform(Vector2(x, centre_z - half_height), r, -1.0)
		hf.deform(Vector2(x, centre_z + half_height), r, -1.0)
		x += step
	return Rect2(mouth_x, centre_z - half_height, depth_m, half_height * 2.0)


## `delay_frames` models a rebuild that does not land on the frame the trench
## appears — amortized across frames, or handed to a worker thread. Units keep
## steering on the STALE field meanwhile, walking into a trench that already
## exists. Whether that actually hurts is the question that decides the fix,
## so it is measured rather than assumed.
func _run(label: String, burrow: bool, uniform: bool, delay_frames := 0) -> Dictionary:
	var hf := Heightfield.new(cfg)
	# Flat ground: the trench must be the only thing that explains a result.
	for i in hf.heights.size():
		hf.heights[i] = cfg.neutral_height

	var field := FlowField.new(cfg)
	field.ignore_terrain = burrow
	field.uniform_cost = uniform

	var goal := Vector2(cfg.cells_x - 12.0, cfg.cells_z * 0.5)
	var goal_cell := Vector2i(int(goal.x), int(goal.y))
	field.build(hf.heights, goal_cell)

	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var pos := PackedVector2Array()
	var travelled := PackedFloat32Array()
	var done := PackedByteArray()
	var cuts := 0
	pos.resize(UNITS); travelled.resize(UNITS); done.resize(UNITS)
	for i in UNITS:
		pos[i] = Vector2(8.0 + rng.randf() * 6.0,
			cfg.cells_z * 0.5 + (rng.randf() - 0.5) * 22.0)
		travelled[i] = 0.0
		done[i] = 0

	var u_rect := Rect2()
	var dug := false
	var pending := -1
	var rebuild_ms := 0.0
	var visited := 0
	var grind_s := 0.0
	var total_s := 0.0
	var t := 0.0

	while t < SIM_LIMIT_S:
		if not dug and t >= DIG_AT_S:
			u_rect = _dig_u(hf, cfg.cells_x * 0.42, cfg.cells_z * 0.5, 16.0, 13.0)
			dug = true
			pending = delay_frames
			if delay_frames == 0:
				rebuild_ms = field.build(hf.heights, goal_cell)
				visited = field.last_visited
				pending = -1
		elif dug and pending > 0:
			pending -= 1
			if pending == 0:
				rebuild_ms = field.build(hf.heights, goal_cell)
				visited = field.last_visited
				pending = -1

		for i in UNITS:
			if done[i] == 1:
				continue
			total_s += DT
			var p: Vector2 = pos[i]
			var dir := field.direction_at(p)
			if dir == Vector2.ZERO:
				grind_s += DT            # no route: counts against us
				continue
			var before := p
			var np := p + dir * UNIT_SPEED * DT
			var c0 := Vector2i(int(p.x), int(p.y))
			var c1 := Vector2i(int(np.x), int(np.y))
			if c0 != c1:
				# Moving diagonally across a cell corner is only legal when
				# both orthogonal neighbours are open.
				if c1.x != c0.x and c1.y != c0.y:
					if not field.is_passable_cell(hf.heights, c1.x, c0.y) \
							or not field.is_passable_cell(hf.heights, c0.x, c1.y):
						cuts += 1
				if not field.is_passable_cell(hf.heights, c1.x, c1.y):
					grind_s += DT
					continue             # blocked: stand still, counts as grinding
			pos[i] = np
			travelled[i] += before.distance_to(np)
			if np.distance_to(goal) < 2.5:
				done[i] = 1
		t += DT

	var arrived := 0
	var trapped := 0
	var path_sum := 0.0
	for i in UNITS:
		if done[i] == 1:
			arrived += 1
			path_sum += travelled[i]
		elif u_rect.has_point(pos[i]):
			trapped += 1

	var res := {
		"arrival": float(arrived) / float(UNITS),
		"trapped": trapped,
		"grind": grind_s / maxf(0.001, total_s),
		"cuts": cuts,
		"mean_path": path_sum / maxi(1, arrived),
		"rebuild_ms": rebuild_ms,
		"visited": visited,
	}
	_lines.append("  %s: %d/%d arrived, %d trapped, %.2f%% grinding, mean path %.1f m, rebuild %.1f ms"
		% [label.rpad(13), arrived, UNITS, trapped, res.grind * 100.0, res.mean_path, rebuild_ms])
	return res
