extends SceneTree
## Build the test map, validate it, and emit artefacts for the spikes and for
## Blender. A test map nobody measured is a guess, so this asserts the map has
## the properties the spikes actually need.
##
##   godot --headless --path . --script tools/build_test_map.gd

const OUT_DIR := "res://build/terrain"
const MAP := "res://data/terrain/test_map_01.tres"

var _failed := 0


func _initialize() -> void:
	var map: TerrainMap = load(MAP)
	var cfg: TerrainConfig = map.terrain
	print("TEST MAP — %s  (%dx%d cells)\n" % [map.display_name, cfg.cells_x, cfg.cells_z])

	var t0 := Time.get_ticks_usec()
	var hf := TerrainBuilder.build(map)
	var build_ms := (Time.get_ticks_usec() - t0) / 1000.0

	# Determinism: seed + ops must reproduce bit-identically, or "seed + diff"
	# is not a viable save format (risk item 3).
	var again := TerrainBuilder.build(map)
	var identical := true
	for i in hf.heights.size():
		if hf.heights[i] != again.heights[i]:
			identical = false
			break
	_ok("rebuild is bit-identical", identical, "seed + %d ops, built in %.1f ms" % [map.ops.size(), build_ms])

	# --- terrain mix -------------------------------------------------------
	var n := hf.heights.size()
	var chasm := 0
	var rough := 0
	for i in n:
		var h := hf.heights[i]
		if h <= cfg.impassable_below:
			chasm += 1
		elif h < cfg.rough_below:
			rough += 1
	var passable := n - chasm
	var rough_pct := float(rough) / n * 100.0
	var chasm_pct := float(chasm) / n * 100.0
	_ok("has meaningful rough ground", rough_pct >= 5.0,
		"%.1f%% rough — Spike B could not compare weighted vs uniform cost without it" % rough_pct)
	_ok("has meaningful impassable ground", chasm_pct >= 2.0,
		"%.1f%% chasm, %.1f%% passable" % [chasm_pct, float(passable) / n * 100.0])

	# --- connectivity ------------------------------------------------------
	var field := FlowField.new(cfg)
	field.build(hf.heights, Vector2i(int(map.goal.x), int(map.goal.y)))
	var spawn_cell := Vector2i(int(map.spawn.x), int(map.spawn.y))
	_ok("goal is reachable from spawn", field.is_reachable(spawn_cell.x, spawn_cell.y),
		"cost-to-goal %.1f over %d reachable cells" %
		[field.cost_at_cell(spawn_cell.x, spawn_cell.y), field.last_visited])

	# Unreachable passable ground = pockets sealed off by the chasm. A couple
	# is fine and interesting; a lot means the map is fragmented.
	var stranded := 0
	for z in cfg.cells_z:
		for x in cfg.cells_x:
			if hf.heights[z * cfg.cells_x + x] > cfg.impassable_below \
					and not field.is_reachable(x, z):
				stranded += 1
	var stranded_pct := float(stranded) / float(passable) * 100.0
	_ok("map is not fragmented", stranded_pct < 8.0,
		"%.1f%% of passable ground is cut off from the goal" % stranded_pct)

	# --- the U pocket must actually be a dead end --------------------------
	# Inside the U, cost-to-goal must be strictly worse than at its mouth,
	# or units would have no reason to route around it.
	var inside := field.cost_at_cell(100, 56)
	var mouth := field.cost_at_cell(88, 56)
	_ok("U pocket is a genuine dead end", inside > mouth,
		"inside %.1f vs mouth %.1f — costlier inside, so the field routes around" % [inside, mouth])

	# --- weighted vs uniform must actually take DIFFERENT ROUTES -----------
	# Comparing the two fields' cost numbers is meaningless: one is measured in
	# time-equivalent, the other in cells travelled. Trace the actual paths and
	# count the rough cells each one chooses to cross.
	var uni := FlowField.new(cfg)
	uni.uniform_cost = true
	uni.build(hf.heights, Vector2i(int(map.goal.x), int(map.goal.y)))
	var w_path := _trace(field, hf, spawn_cell)
	var u_path := _trace(uni, hf, spawn_cell)
	_ok("weighted avoids rough, uniform does not",
		w_path.rough < u_path.rough * 0.6,
		"weighted crosses %d rough cells in %d steps; uniform crosses %d in %d" %
		[w_path.rough, w_path.steps, u_path.rough, u_path.steps])

	# --- artefacts ---------------------------------------------------------
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var raw := FileAccess.open(OUT_DIR + "/test_map_01.r32", FileAccess.WRITE)
	raw.store_buffer(hf.heights.to_byte_array())
	raw.close()

	var img := Image.create_empty(cfg.cells_x, cfg.cells_z, false, Image.FORMAT_RGB8)
	for z in cfg.cells_z:
		for x in cfg.cells_x:
			var h := hf.heights[z * cfg.cells_x + x]
			var c: Color
			if h <= cfg.impassable_below:
				c = Color(0.05, 0.07, 0.14)
			elif h < cfg.rough_below:
				c = Color(0.42, 0.30, 0.16).lerp(Color(0.55, 0.42, 0.22),
					(h - cfg.impassable_below) / (cfg.rough_below - cfg.impassable_below))
			else:
				c = Color(0.33, 0.31, 0.37).lerp(Color(0.72, 0.70, 0.76),
					clampf((h - cfg.rough_below) / 0.4, 0.0, 1.0))
			img.set_pixel(x, z, c)
	img.save_png(OUT_DIR + "/test_map_01_legend.png")

	var grey := Image.create_empty(cfg.cells_x, cfg.cells_z, false, Image.FORMAT_L8)
	for z in cfg.cells_z:
		for x in cfg.cells_x:
			var h := hf.heights[z * cfg.cells_x + x]
			grey.set_pixel(x, z, Color(h, h, h))
	grey.save_png(OUT_DIR + "/test_map_01_height.png")

	print("\nartefacts in %s" % ProjectSettings.globalize_path(OUT_DIR))
	print("  test_map_01.r32           %d x %d float32, row-major (for Blender)" % [cfg.cells_x, cfg.cells_z])
	print("  test_map_01_height.png    greyscale heightmap")
	print("  test_map_01_legend.png    passability legend — chasm / rough / clear")

	print("")
	if _failed == 0:
		print("TEST MAP: OK — usable as a fixture for Spike A and Spike B.")
	else:
		print("TEST MAP: %d check(s) failed." % _failed)
	quit(1 if _failed > 0 else 0)


## Walk a field from `start` to the goal, reporting how much rough ground the
## route actually chose to cross.
func _trace(field: FlowField, hf: Heightfield, start: Vector2i) -> Dictionary:
	var cfg := hf.cfg
	var c := start
	var steps := 0
	var rough := 0
	while steps < cfg.cells_x * cfg.cells_z:
		var d := field.flow[field.index(c.x, c.y)]
		if d == FlowField.NO_DIR:
			break
		var h := hf.heights[c.y * cfg.cells_x + c.x]
		if h > cfg.impassable_below and h < cfg.rough_below:
			rough += 1
		var v: Vector2i = FlowField.DIRS[d]
		c += v
		steps += 1
		if not field.in_bounds(c.x, c.y):
			break
	return {"steps": steps, "rough": rough}


func _ok(name: String, cond: bool, detail: String) -> void:
	if not cond:
		_failed += 1
	print("  %s  %s  %s" % ["PASS" if cond else "FAIL", name.rpad(32), detail])
