extends SceneTree
## Authors the biodome map, its palette and its dressing, and checks the result.
##
##   godot --headless --path . --script tools/build_biodome.gd
##
## The reference is the bioluminescent-cavern painting in the brief: a dark
## valley floor, glowing teal channels winding through it, a pale raised path,
## rocky ledges, and living architecture growing out of all of it.
##
## Authored as a SEED PLUS OPS, never as a stored heightfield — CLAUDE.md risk
## item 3. The dressing is the same idea: rules and a seed, not two hundred
## saved transforms.

const MAP_OUT := "res://data/terrain/biodome_map_01.tres"
const PALETTE_OUT := "res://data/biomes/biodome_01_palette.tres"
const DRESSING_OUT := "res://data/biomes/biodome_01_dressing.tres"
const TERRAIN_CFG := "res://data/terrain/biodome_01.tres"

## Where the module comes down. Everything else is authored around it.
const LANDING := Vector2(30.0, 56.0)

var _failed := 0


func _initialize() -> void:
	print("SENTINEL — biodome 01\n")
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path("res://data/biomes/"))
	var map := _map()
	_save(map, MAP_OUT)
	_save(_palette(), PALETTE_OUT)
	var plan := _dressing()
	_save(plan, DRESSING_OUT)
	_check(map, plan)
	_export_preview(map, plan)
	print("")
	if _failed == 0:
		print("BIODOME 01: OK")
	else:
		print("%d CHECK(S) FAILED" % _failed)
	quit(_failed)


func _save(res: Resource, path: String) -> void:
	var err := ResourceSaver.save(res, path)
	print("  %s  %s" % ["wrote " if err == OK else "FAILED", path])
	if err != OK:
		_failed += 1


func _ok(name: String, cond: bool, detail: String) -> void:
	if not cond:
		_failed += 1
	print("  %s  %s  %s" % ["PASS" if cond else "FAIL", name.rpad(38), detail])


# --- the landscape ----------------------------------------------------------
## Stamp discs along a polyline. Every shape on this map is made of these: a
## channel is a line of low discs, a path is a line of high ones, a ledge is a
## fat one. Keeps the whole map inside the four ops TerrainMap can express.
func _run(ops: Array[Dictionary], pts: Array, r: float, level: float,
		strength := 1.0, step := 3.0) -> void:
	for i in pts.size() - 1:
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[i + 1]
		var n := maxi(1, int(a.distance_to(b) / step))
		for k in n + 1:
			var p := a.lerp(b, float(k) / n)
			ops.append({"op": "plateau", "x": p.x, "z": p.y,
				"r": r, "level": level, "strength": strength})


func _map() -> TerrainMap:
	var m := TerrainMap.new()
	m.display_name = "Biodome 01 — the drowned garden"
	m.terrain = load(TERRAIN_CFG)
	m.noise_seed = 20260915
	# Gentler than the test map: this is a valley floor, and the big shapes
	# below should read as deliberate rather than fighting the noise.
	m.amplitude = 0.26
	m.octaves = [Vector2(0.045, 0.58), Vector2(0.125, 0.30), Vector2(0.29, 0.12)]
	m.spawn = LANDING
	m.goal = Vector2(132.0, 84.0)

	var ops: Array[Dictionary] = []

	# Rocky ledges along the north and west, so the valley has walls to read
	# against. High enough to be ridge-coloured and steep enough that nothing
	# grows on the faces.
	_run(ops, [Vector2(6, 8), Vector2(46, 4), Vector2(92, 10), Vector2(140, 6)],
		13.0, 0.92, 0.85, 5.0)
	_run(ops, [Vector2(4, 30), Vector2(8, 62), Vector2(4, 100)], 11.0, 0.88, 0.80, 5.0)
	_run(ops, [Vector2(96, 104), Vector2(138, 108)], 12.0, 0.86, 0.75, 5.0)

	# The glowing channels. Below impassable_below (0.26) they are standing
	# liquid — the brightest thing on the map and an impassable barrier, which
	# is the point: the pools shape where an army can walk.
	#
	# Two passes each, and the order matters. A single deep stamp goes from
	# ridge to water in about four metres, which leaves almost no ground in the
	# rough band and turns every pool into a kerb. The wide shallow BANK is
	# stamped first, then the deep channel inside it, so there is a metre or
	# three of boggy shoreline the player can cross slowly and units can be
	# caught on.
	# Narrow and branching, not lakes. The first pass used seven-metre radii and
	# the plan view came back as three ponds — at this map size a channel has
	# to be about four metres across before it reads as something that wound
	# its way here rather than something that was stamped.
	var channels := [
		[Vector2(14, 22), Vector2(34, 34), Vector2(52, 28), Vector2(72, 42)],
		[Vector2(72, 42), Vector2(84, 60), Vector2(80, 82), Vector2(94, 102)],
		[Vector2(52, 28), Vector2(58, 14), Vector2(74, 8)],
		[Vector2(84, 60), Vector2(104, 58), Vector2(120, 48)],
		[Vector2(108, 26), Vector2(124, 42), Vector2(133, 64)],
		[Vector2(133, 64), Vector2(126, 86), Vector2(134, 104)],
		[Vector2(18, 80), Vector2(38, 94), Vector2(60, 100)],
		[Vector2(38, 94), Vector2(34, 74), Vector2(22, 64)],
	]
	var radii := [4.4, 4.6, 3.2, 3.4, 3.8, 3.4, 3.6, 2.9]
	var depths := [0.11, 0.09, 0.16, 0.15, 0.13, 0.15, 0.14, 0.17]
	for i in channels.size():
		_run(ops, channels[i], radii[i] + 5.5, 0.32, 0.62, 2.0)   # boggy bank
		_run(ops, channels[i], radii[i], depths[i], 0.95, 2.0)     # water

	# The pale path. Raised, narrow and winding, from the landing site to the
	# far corner — the one piece of ground the player can always walk, and the
	# thing the eye follows in the reference image.
	_run(ops, [LANDING, Vector2(48, 62), Vector2(62, 56), Vector2(78, 66),
			Vector2(92, 78), Vector2(112, 76), Vector2(132, 84)],
		3.6, 0.74, 0.88, 2.0)

	# The landing clearing itself: flat, neutral, and wide enough to build in.
	ops.append({"op": "plateau", "x": LANDING.x, "z": LANDING.y,
		"r": 14.0, "level": 0.56, "strength": 0.92})

	# Two shallow basins either side of the path — rough ground, not pools, so
	# there is somewhere that slows an army without stopping it.
	ops.append({"op": "plateau", "x": 58.0, "z": 86.0, "r": 15.0,
		"level": 0.33, "strength": 0.7})
	ops.append({"op": "plateau", "x": 104.0, "z": 54.0, "r": 13.0,
		"level": 0.34, "strength": 0.7})
	m.ops = ops
	return m


# --- the look ---------------------------------------------------------------
func _palette() -> BiomePalette:
	var p := BiomePalette.new()
	p.display_name = "Biodome 01"
	p.col_pool = Color(0.020, 0.135, 0.130)
	p.col_rough = Color(0.105, 0.180, 0.145)
	p.col_ground = Color(0.140, 0.180, 0.185)
	p.col_ridge = Color(0.560, 0.575, 0.545)
	p.col_cliff = Color(0.085, 0.100, 0.120)
	p.fog_tint = Color(0.014, 0.030, 0.042)
	p.pool_glow = Color(0.16, 0.95, 0.83)
	p.pool_glow_strength = 2.6
	p.vein_glow = Color(0.28, 0.93, 0.66)
	p.vein_strength = 0.42
	p.vein_scale = 0.052
	p.vein_sharpness = 10.0
	# Left ON. It is a readability aid and this is still a grey-box slice —
	# turn it to 0 for a screenshot, not for a playtest.
	p.threshold_line_strength = 0.85
	return p


# --- what grows on it -------------------------------------------------------
func _entry(model: String, count: int, lo: float, hi: float, slope: float,
		clearance: float, smin: float, smax: float, lean: float,
		clusters := 0, cluster_r := 9.0, shadow := true) -> PropScatter:
	var e := PropScatter.new()
	e.model = model
	e.count = count
	e.height_min = lo
	e.height_max = hi
	e.max_slope = slope
	e.clearance_m = clearance
	e.scale_min = smin
	e.scale_max = smax
	e.follow_slope = lean
	e.clusters = clusters
	e.cluster_radius_m = cluster_r
	e.casts_shadow = shadow
	e.sink_m = 0.10
	return e


func _dressing() -> BiomeDressing:
	var d := BiomeDressing.new()
	d.display_name = "Biodome 01"
	d.seed = 20260915
	d.landing_clear_m = 12.0
	# Counts are a PERFORMANCE decision as much as a visual one. These six add
	# up to roughly 87k triangles if every one of them were on screen at once,
	# in six draw calls — and fog means only the explored ones are ever
	# submitted. Spike A measured the terrain unlit and undressed; this needs a
	# re-run on the phone before the number is trusted.
	var entries: Array[PropScatter] = [
		# Landmarks. Few, large, well clear of each other and of the path, and
		# big enough to dominate — the first pass scaled them 0.85-1.45 and
		# they read as croquet hoops from the RTS camera.
		_entry("flora_arch", 16, 0.42, 0.78, 0.26, 15.0, 1.30, 2.40, 0.10, 6, 26.0),
		_entry("flora_brain", 11, 0.46, 0.86, 0.30, 13.0, 1.10, 1.95, 0.15, 5, 22.0),
		# The mid-ground mat, in thickets rather than evenly spread. Growth in
		# a cavern crowds where the light and the water are and leaves bare
		# ground between; a uniform scatter reads as a lawn.
		#
		# These three fringe the waterline deliberately: their height_min sits
		# just BELOW impassable_below (0.26), so they stand ankle-deep in the
		# shallows the way the reference does. Nothing is allowed out into the
		# deep channel, which is checked below.
		_entry("flora_tendril", 120, 0.215, 0.66, 0.48, 2.4, 1.00, 2.10, 0.45,
			14, 13.0, false),
		_entry("flora_coral", 95, 0.220, 0.56, 0.46, 2.0, 0.95, 1.85, 0.30,
			12, 11.0, false),
		_entry("flora_pods", 150, 0.215, 0.80, 0.58, 1.5, 0.85, 1.60, 0.55,
			18, 10.0, false),
		# Rock: the only thing here that is not alive, and the only thing that
		# lies down with the slope it is standing on.
		_entry("rock_spire", 70, 0.58, 1.00, 0.80, 2.8, 0.85, 2.10, 0.85, 9, 16.0),
	]
	d.entries = entries
	return d


# --- does the map work ------------------------------------------------------
func _check(map: TerrainMap, plan: BiomeDressing) -> void:
	print("\nthe map")
	var field := TerrainBuilder.build(map)
	var cfg := field.cfg
	var total := cfg.cells_x * cfg.cells_z
	var pool := 0
	var rough := 0
	var ridge := 0
	for h in field.heights:
		if h < cfg.impassable_below:
			pool += 1
		elif h < cfg.rough_below:
			rough += 1
		elif h > 0.72:
			ridge += 1
	var pct := func(n): return 100.0 * n / total

	_ok("the map is the size it says", total == 150 * 112,
		"%d x %d m" % [cfg.cells_x, cfg.cells_z])
	# Pools have to be a real barrier and not the whole floor. Too few and the
	# glow is decoration; too many and there is nowhere to fight.
	_ok("pools cut the valley without drowning it", pool > total * 0.04 and pool < total * 0.22,
		"%.1f%% impassable liquid" % pct.call(pool))
	_ok("there is rough shoreline to slow an army", rough > total * 0.05,
		"%.1f%% rough" % pct.call(rough))
	_ok("there are ledges to read the valley against", ridge > total * 0.06,
		"%.1f%% ridge" % pct.call(ridge))

	# The landing site must be flat, dry and buildable, or the first minute of
	# the game opens with the module in a pond.
	_ok("the landing site is dry", field.is_passable(LANDING),
		"height %.2f at %.0f, %.0f" % [field.height_at(LANDING), LANDING.x, LANDING.y])
	var slope_here := Dressing.slope_at(field, LANDING)
	_ok("and flat enough to build on", slope_here < 0.12, "slope %.3f" % slope_here)

	# The pale path is the promise that there is always a way through. Walk it.
	var route: Array[Vector2] = [LANDING, Vector2(48, 62), Vector2(62, 56),
		Vector2(78, 66), Vector2(92, 78), Vector2(112, 76), Vector2(132, 84)]
	var blocked := 0
	var steps := 0
	for i in route.size() - 1:
		var n := int(route[i].distance_to(route[i + 1]))
		for k in n + 1:
			steps += 1
			if not field.is_passable(route[i].lerp(route[i + 1], float(k) / n)):
				blocked += 1
	_ok("the path is walkable end to end", blocked == 0,
		"%d of %d metres passable" % [steps - blocked, steps])

	print("\nthe dressing")
	var placed := Dressing.place(field, plan, LANDING)
	var got := 0
	var short := PackedStringArray()
	for model in placed:
		var n: int = placed[model].size()
		got += n
		var want := 0
		for e in plan.entries:
			if e.model == model:
				want = e.count
		print("    %-16s %3d of %3d" % [model, n, want])
		if n < want * 0.75:
			short.append("%s %d/%d" % [model, n, want])
	_ok("the scatter finds room for what it promised", short.is_empty(),
		"%d of %d props placed" % [got, plan.total_props()])

	# Nothing on top of the player; growth at the waterline but not out in the
	# deep. Three of the six entries have a height_min below the 0.26 waterline
	# on purpose — that fringe is most of what makes the pools read as alive —
	# so the rule being checked is depth, not wetness.
	const DEEP := 0.19
	var on_landing := 0
	var fringing := 0
	var drowned := 0
	for model in placed:
		for t in placed[model]:
			var p := Vector2(t.origin.x, t.origin.z)
			if p.distance_to(LANDING) < plan.landing_clear_m:
				on_landing += 1
			var h := field.height_at(p)
			if h < DEEP:
				drowned += 1
			elif h < cfg.impassable_below:
				fringing += 1
	_ok("nothing grows on the landing site", on_landing == 0,
		"%.0f m clear" % plan.landing_clear_m)
	_ok("nothing grows out in deep water", drowned == 0,
		"%d below %.2f" % [drowned, DEEP])
	_ok("but the shallows are not bare", fringing > 0,
		"%d props standing at the waterline" % fringing)

	# And the same seed twice is the same map, or none of this is saveable.
	var again := Dressing.place(TerrainBuilder.build(map), plan, LANDING)
	var same := true
	for model in placed:
		if placed[model].size() != again[model].size():
			same = false
			break
		for i in placed[model].size():
			if not placed[model][i].origin.is_equal_approx(again[model][i].origin):
				same = false
				break
	_ok("the same seed gives the same map", same, "rebuilt identically")


# --- preview export ---------------------------------------------------------
## Write the heightfield and the prop placements where Blender can read them.
##
## This is not an art export. It is the only way to actually LOOK at a map that
## is authored as a seed plus a list of ops — the numbers above say the pools
## cut the valley and the path goes through, but they cannot say whether it
## reads as the place in the reference painting.
func _export_preview(map: TerrainMap, plan: BiomeDressing) -> void:
	const OUT := "res://build/biodome"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var field := TerrainBuilder.build(map)
	var cfg := field.cfg

	var raw := FileAccess.open(OUT + "/biodome_01.r32", FileAccess.WRITE)
	if raw == null:
		_failed += 1
		print("  FAILED to write the heightfield")
		return
	for h in field.heights:
		raw.store_float(h)
	raw.close()

	var placed := Dressing.place(field, plan, LANDING)
	var props := []
	for model in placed:
		var rows := []
		for t in placed[model]:
			var tr: Transform3D = t
			# Uniform scale and a yaw are all the scatter produces, plus a
			# partial lean; hand Blender the basis columns and let it rebuild
			# the matrix rather than trying to round-trip Euler angles.
			rows.append({
				"o": [tr.origin.x, tr.origin.y, tr.origin.z],
				"x": [tr.basis.x.x, tr.basis.x.y, tr.basis.x.z],
				"y": [tr.basis.y.x, tr.basis.y.y, tr.basis.y.z],
				"z": [tr.basis.z.x, tr.basis.z.y, tr.basis.z.z],
			})
		props.append({"model": model, "at": rows})

	var pal := _palette()
	var meta := FileAccess.open(OUT + "/biodome_01.json", FileAccess.WRITE)
	meta.store_string(JSON.stringify({
		"cells_x": cfg.cells_x, "cells_z": cfg.cells_z,
		"height_scale_m": cfg.height_scale_m,
		"impassable_below": cfg.impassable_below, "rough_below": cfg.rough_below,
		"landing": [LANDING.x, LANDING.y],
		"palette": {
			"pool": pal.col_pool.to_html(false), "rough": pal.col_rough.to_html(false),
			"ground": pal.col_ground.to_html(false), "ridge": pal.col_ridge.to_html(false),
			"cliff": pal.col_cliff.to_html(false),
			"pool_glow": pal.pool_glow.to_html(false),
			"pool_glow_strength": pal.pool_glow_strength,
			"vein_glow": pal.vein_glow.to_html(false),
		},
		"props": props,
	}, "  "))
	meta.close()
	print("\n  wrote   %s/biodome_01.r32   %d x %d float32" % [OUT, cfg.cells_x, cfg.cells_z])
	print("  wrote   %s/biodome_01.json  %d prop kinds" % [OUT, props.size()])
