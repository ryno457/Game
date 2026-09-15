extends SceneTree
## Authors the biodome map, its palette and its dressing, and checks the result.
##
##   godot --headless --path . --script tools/build_biodome.gd
##
## The reference is the top-down survey map in the brief: rounded plateaus
## joined by narrow necks, glowing basins in the hollows, and cloud where the
## ground runs out. This is a HIGH MOUNTAIN RANGE seen from above — the peaks
## stand over a cloud deck, not over space.
##
## That changes what a map IS. The default state of the world is now "no ground
## here": the base noise sits far below the palette's `void_below`, nothing is
## drawn there, and every island is something the ops list explicitly raised.
##
## Authored as a SEED PLUS OPS, never as a stored heightfield — CLAUDE.md risk
## item 3. The dressing is the same idea: rules and a seed, not two hundred
## saved transforms.

const MAP_OUT := "res://data/terrain/biodome_map_01.tres"
const PALETTE_OUT := "res://data/biomes/biodome_01_palette.tres"
const DRESSING_OUT := "res://data/biomes/biodome_01_dressing.tres"
const CLOUDS_OUT := "res://data/biomes/biodome_01_clouds.tres"
const TERRAIN_CFG := "res://data/terrain/biodome_01.tres"

## Where the module comes down. Everything else is authored around it.
const LANDING := Vector2(30.0, 40.0)
## The far island. The route between the two has to exist across the necks, and
## that is checked with a real flow field rather than by eye.
const GOAL := Vector2(120.0, 86.0)

## Ground below this is not drawn at all. Between it and `impassable_below`
## (0.26) sits a rim of real-but-unwalkable ground — the cliff edge a peak
## falls away over, which is what stops an island looking like a cut-out.
const VOID_BELOW := 0.16

## centre, radius, height of the top
const ISLANDS := [
	[Vector2(30, 34), 24.0, 0.66],
	[Vector2(28, 82), 21.0, 0.62],
	[Vector2(76, 56), 20.0, 0.70],
	[Vector2(118, 32), 23.0, 0.64],
	[Vector2(120, 86), 20.0, 0.60],
]

## The necks. Narrow on purpose: a land bridge the width of a road is a
## chokepoint an army has to fight over, which is the whole point of putting
## the ground in separate pieces.
const NECKS := [
	[Vector2(44, 38), Vector2(62, 50)],
	[Vector2(44, 76), Vector2(62, 62)],
	[Vector2(92, 50), Vector2(104, 38)],
	[Vector2(92, 66), Vector2(106, 80)],
	[Vector2(20, 52), Vector2(22, 66)],
]

var _failed := 0


func _initialize() -> void:
	print("SENTINEL — biodome 01\n")
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path("res://data/biomes/"))
	var map := _map()
	_save(map, MAP_OUT)
	_save(_palette(), PALETTE_OUT)
	_save(_clouds(), CLOUDS_OUT)
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
	m.display_name = "Biodome 01 — the cloud shelf"
	m.terrain = load(TERRAIN_CFG)
	m.noise_seed = 20260915
	# The base sits BELOW the world edge, so the default state of every cell is
	# "no ground". An island is not a hill carved out of a plain here — it is
	# the only thing that exists.
	m.base_level = 0.055
	m.amplitude = 0.10
	m.octaves = [Vector2(0.045, 0.58), Vector2(0.125, 0.30), Vector2(0.29, 0.12)]
	m.spawn = LANDING
	m.goal = GOAL

	var ops: Array[Dictionary] = []

	# The islands. One broad disc each: the cosine-squared falloff takes the top
	# down to the base over the radius on its own, which is exactly the rounded
	# shoulder-then-cliff profile the reference has.
	for isl in ISLANDS:
		var c: Vector2 = isl[0]
		ops.append({"op": "plateau", "x": c.x, "z": c.y,
			"r": isl[1], "level": isl[2], "strength": 0.97})

	# The necks, stamped after the islands so they bridge whatever the falloffs
	# left between them. Level is below every island top, so a neck reads as a
	# saddle rather than a causeway laid across the gap.
	for n in NECKS:
		_run(ops, [n[0], n[1]], 7.0, 0.50, 0.93, 2.0)

	# Flat tops. Without these an island is a cone and there is nowhere to
	# build; with them it is a plateau with a rim, which is what the reference
	# shows and what a convoy needs.
	for isl in ISLANDS:
		var c: Vector2 = isl[0]
		ops.append({"op": "plateau", "x": c.x, "z": c.y,
			"r": isl[1] * 0.58, "level": isl[2] - 0.06, "strength": 0.80})

	# Ridges along the rims — the rock in the reference sits at the edges, not
	# in the middle, because that is where a peak is steepest.
	ops.append({"op": "plateau", "x": 14.0, "z": 24.0, "r": 9.0,
		"level": 0.90, "strength": 0.80})
	ops.append({"op": "plateau", "x": 62.0, "z": 46.0, "r": 7.0,
		"level": 0.88, "strength": 0.75})
	ops.append({"op": "plateau", "x": 132.0, "z": 96.0, "r": 9.0,
		"level": 0.87, "strength": 0.78})
	ops.append({"op": "plateau", "x": 108.0, "z": 20.0, "r": 8.0,
		"level": 0.89, "strength": 0.78})

	# The glowing basins, in the hollows on the island tops. Banked first and
	# cut inside, same as before: a single deep stamp goes rim-to-water in four
	# metres and leaves no shoreline to stand on.
	var basins := [
		[Vector2(70, 51), 6.5, 0.17],
		[Vector2(84, 61), 5.5, 0.16],
		[Vector2(26, 30), 6.0, 0.19],
		[Vector2(122, 28), 5.5, 0.18],
		[Vector2(30, 86), 5.0, 0.20],
	]
	for b in basins:
		var c: Vector2 = b[0]
		var r: float = b[1]
		ops.append({"op": "plateau", "x": c.x, "z": c.y,
			"r": r + 5.0, "level": 0.32, "strength": 0.62})
		# "water": true also stamps the water mask, which is the only thing
		# that tells the shader this is a pool and not the outer rim of an
		# island — they are the same height, and before this every island was
		# ringed with a neon halo.
		ops.append({"op": "plateau", "x": c.x, "z": c.y,
			"r": r, "level": b[2], "strength": 0.95, "water": true})

	# The landing clearing: flat, dry, buildable, and clear of the rim.
	ops.append({"op": "plateau", "x": LANDING.x, "z": LANDING.y,
		"r": 11.0, "level": 0.56, "strength": 0.92})
	m.ops = ops
	return m


# --- the look ---------------------------------------------------------------
## The five things the ground is made of.
##
## Read straight off the reference: the plateau interiors are large flat areas
## of pale sage and teal, the rims are a dark root mat, bare rock shows on the
## steep parts and the ridge tops, and there is pale sediment at every
## waterline. Each is TWO values a painter would have mixed, not one flat fill.
func _material(id: int, mname: String, col: Color, alt: Color,
		rough: float, vein: float, stroke: float) -> GroundMaterial:
	var m := GroundMaterial.new()
	m.id = StringName(GroundMaterials.NAMES[id].to_upper())
	m.display_name = mname
	m.colour = col
	m.colour_alt = alt
	m.roughness = rough
	m.vein_strength = vein
	m.stroke_scale_mult = stroke
	return m


func _materials() -> Array[GroundMaterial]:
	var out: Array[GroundMaterial] = []
	out.resize(GroundMaterials.COUNT)
	# Open moss flats — most of every plateau top, and deliberately CLEAR of the
	# glowing web. This slot is the answer to "not all the ground is vines".
	out[GroundMaterials.MOSS] = _material(GroundMaterials.MOSS, "Moss flat",
		Color(0.255, 0.400, 0.335), Color(0.330, 0.470, 0.395), 0.88, 0.0, 1.0)
	# Bare rock: steep faces and ridge tops. Shorter, choppier marks.
	out[GroundMaterials.ROCK] = _material(GroundMaterials.ROCK, "Bare rock",
		Color(0.235, 0.270, 0.310), Color(0.330, 0.365, 0.405), 0.94, 0.0, 1.9)
	# Pale sediment at every waterline — the lightest thing on the map after the
	# ridges, which is what makes the basins read from above.
	out[GroundMaterials.SEDIMENT] = _material(GroundMaterials.SEDIMENT, "Sediment",
		Color(0.520, 0.575, 0.520), Color(0.620, 0.660, 0.600), 0.80, 0.05, 0.75)
	# Darker soil in broad patches, so the flats are not one colour.
	out[GroundMaterials.LOAM] = _material(GroundMaterials.LOAM, "Loam",
		Color(0.150, 0.235, 0.230), Color(0.205, 0.300, 0.280), 0.90, 0.10, 1.15)
	# The root mat. The ONLY slot with a real vein strength, so the filament web
	# rings each plateau instead of covering it.
	out[GroundMaterials.VINE] = _material(GroundMaterials.VINE, "Root mat",
		Color(0.085, 0.175, 0.145), Color(0.130, 0.245, 0.185), 0.85, 1.35, 0.85)
	return out


func _palette() -> BiomePalette:
	var p := BiomePalette.new()
	p.materials = _materials()
	p.material_jitter_m = 1.8
	p.display_name = "Biodome 01"
	# Brighter than the cavern version, and deliberately so. That palette was
	# written for ground lit from inside by its own pools; this map is a
	# mountain top under open sky, and the same colours came back as five black
	# silhouettes with a glowing outline.
	p.col_pool = Color(0.030, 0.165, 0.160)
	p.col_rough = Color(0.185, 0.275, 0.215)
	p.col_ground = Color(0.290, 0.355, 0.330)
	p.col_ridge = Color(0.640, 0.655, 0.620)
	p.col_cliff = Color(0.150, 0.170, 0.195)
	p.fog_tint = Color(0.030, 0.055, 0.070)
	p.pool_glow = Color(0.16, 0.95, 0.83)
	# The reference has a teal basin and a violet one side by side. One
	# low-frequency field picks which tint a basin takes, so a whole pool is
	# one colour and the next one over is the other.
	p.pool_glow_alt = Color(0.78, 0.30, 0.96)
	p.pool_alt_mix = 0.85
	p.pool_glow_strength = 2.6
	p.vein_glow = Color(0.28, 0.93, 0.66)
	# Global multiplier now; WHERE the web grows is decided per material, and
	# only the root mat has a real value. Back up from 0.20 because it is no
	# longer competing with the brush marks across the whole map — it only
	# appears on the rims.
	p.vein_strength = 0.55
	p.vein_scale = 0.052
	p.vein_sharpness = 10.0
	# Left ON. It is a readability aid and this is still a grey-box slice —
	# turn it to 0 for a screenshot, not for a playtest.
	# Painterly. Tuned for the overhead camera: strokes about a metre long
	# running along the contours, five value steps, and a light posterise.
	p.paint_strength = 0.85
	p.paint_bands = 5.0
	# SIZE MATTERS MORE THAN ANYTHING ELSE HERE. The first pass used a scale of
	# 1.15 with a stretch of 7.5, which makes a stroke about 90 cm long and 12 cm
	# across — under a pixel wide from the RTS camera, so every mark aliased
	# into noise and the paint pass changed nothing. These are strokes roughly
	# four metres long and most of a metre across: brush marks at the scale the
	# camera actually sees.
	p.stroke_scale = 0.22
	p.stroke_stretch = 5.0
	p.stroke_depth = 0.62
	p.paint_quantise = 14.0
	p.edge_ink = 0.45
	p.paint_tone = 0.55
	p.canvas_grain = 0.10
	# Ink. The reference has linework around every shape; this is depth-only
	# because the normal buffer does not exist on the Mobile renderer.
	p.ink_colour = Color(0.020, 0.052, 0.058)
	# Turned down from 0.80 / 0.010 / 0.0026: at those values the cliffs inked
	# as a solid dark wash rather than a line, because a rim's second
	# difference is enormous compared with a plateau's. Ink is a line.
	p.ink_strength = 0.55
	p.ink_silhouette = 0.020
	p.ink_crease = 0.0060
	p.ink_thickness_px = 1.4
	p.ink_fade_m = 150.0
	p.threshold_line_strength = 0.85
	# Below this nothing is drawn and the cloud deck shows through. See
	# VOID_BELOW for why it sits under impassable_below rather than on it.
	p.void_below = VOID_BELOW
	# The survey grid from the reference. Ten metres reads as a useful ruler
	# from the overhead camera without turning the ground into graph paper.
	p.grid_spacing_m = 10.0
	p.grid_colour = Color(0.55, 0.88, 0.95)
	p.grid_strength = 0.13
	return p


## The weather under the map. Height is in world metres: the terrain's lowest
## DRAWN ground is void_below * height_scale_m, so the deck has to sit below
## that or the peaks paddle in it instead of standing over it.
func _clouds() -> CloudConfig:
	var c := CloudConfig.new()
	var cfg: TerrainConfig = load(TERRAIN_CFG)
	c.display_name = "Biodome 01"
	c.height_m = VOID_BELOW * cfg.height_scale_m - 16.0
	c.extent_m = 520.0
	c.lit_colour = Color(0.80, 0.90, 0.99)
	c.shadow_colour = Color(0.16, 0.26, 0.40)
	c.deep_colour = Color(0.035, 0.070, 0.125)
	c.horizon_colour = Color(0.26, 0.50, 0.60)
	c.cloud_scale = 0.013
	c.coverage = 0.46
	c.softness = 0.28
	c.scroll_mps = 0.55
	c.relief = 0.60
	c.fade_start_m = 190.0
	c.fade_end_m = 430.0
	return c


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
	d.landing_clear_m = 11.0
	# Every band now starts ABOVE the world edge (0.16). Anything below that is
	# not ground, it is cloud, and a prop placed there would hang in the air.
	#
	# The rim band is the important one. In the reference the roots and vines
	# ARE the island edges — they ring each plateau where it falls away — so
	# the tendrils and coral are banded into 0.18-0.42 rather than scattered
	# across the tops.
	# COUNTS ARE TUNED TO THE LAND AREA, and the land area just fell by two
	# thirds: only 31% of this map is ground at all, and the flat tops are a
	# fraction of that. The first pass kept the valley map's counts and the
	# scatter could place 7 arches out of 16 and 2 spires out of 70 — it was
	# not failing, it was being asked for something that does not fit.
	# ORDER IS PRIORITY. Dressing.place keeps one shared `taken` list, so an
	# entry has to find room around everything placed before it. Spires used to
	# be last and could only place 9 of 45 — not because the high ground was
	# full, it had twice the area it needed, but because 380 pods and tendrils
	# had already been strewn across it. Big and structural first, clutter last.
	var entries: Array[PropScatter] = [
		# Landmarks, on the flat tops where there is room for them. The two
		# share the same band and the same land, so their budgets have to be
		# read together: about 1600 legal square metres between them.
		_entry("flora_arch", 6, 0.46, 0.78, 0.30, 10.0, 1.30, 2.40, 0.10, 5, 22.0),
		_entry("flora_brain", 4, 0.48, 0.86, 0.34, 10.0, 1.10, 1.95, 0.15, 4, 20.0),
		# Rock on the high ground. Band starts at 0.52, not 0.60: the flat-top
		# op takes six hundredths off every island centre, so almost nothing
		# outside the four ridge stamps was ever above 0.60.
		_entry("rock_spire", 35, 0.52, 1.00, 0.85, 2.4, 0.85, 2.10, 0.85, 9, 14.0),
		# The rim. These are the roots that hold the islands together.
		_entry("flora_tendril", 130, 0.180, 0.42, 0.62, 2.2, 1.00, 2.20, 0.55,
			16, 14.0, false),
		_entry("flora_coral", 80, 0.185, 0.40, 0.55, 1.8, 0.95, 1.85, 0.35,
			14, 12.0, false),
		# Clutter last, into whatever is left.
		_entry("flora_pods", 150, 0.180, 0.80, 0.58, 1.5, 0.85, 1.60, 0.55,
			18, 10.0, false),
	]
	d.entries = entries
	return d


# --- does the map work ------------------------------------------------------
func _check(map: TerrainMap, plan: BiomeDressing) -> void:
	print("\nthe range")
	var field := TerrainBuilder.build(map)
	var mats := TerrainBuilder.classify_materials(field, VOID_BELOW)
	var cfg := field.cfg
	var total := cfg.cells_x * cfg.cells_z
	var drawn := 0
	var walkable := 0
	var rim := 0
	for h in field.heights:
		if h >= VOID_BELOW:
			drawn += 1
			if h >= cfg.impassable_below:
				walkable += 1
			else:
				rim += 1
	var pct := func(n): return 100.0 * n / total

	_ok("the map is the size it says", total == 150 * 112,
		"%d x %d m" % [cfg.cells_x, cfg.cells_z])
	# Peaks over cloud, not a continent with puddles. Too much ground and the
	# islands stop reading as islands; too little and there is nowhere to play.
	_ok("most of the world is cloud", drawn > total * 0.22 and drawn < total * 0.62,
		"%.1f%% is ground" % pct.call(drawn))
	_ok("and the ground is mostly walkable", walkable > drawn * 0.55,
		"%.1f%% of the map, %.1f%% of the ground"
			% [pct.call(walkable), 100.0 * walkable / maxi(1, drawn)])
	# The rim is what stops an island looking like a cut-out: real ground you
	# can see but not stand on, between the walkable top and the drop.
	_ok("every island has a cliff rim", rim > total * 0.04,
		"%.1f%% drawn but unwalkable" % pct.call(rim))

	# The landing site.
	_ok("the landing site is on ground", field.is_passable(LANDING),
		"height %.2f at %.0f, %.0f" % [field.height_at(LANDING), LANDING.x, LANDING.y])
	var slope_here := Dressing.slope_at(field, LANDING)
	_ok("and flat enough to build on", slope_here < 0.12, "slope %.3f" % slope_here)

	# THE CHECK THAT MATTERS. The islands are only a design if you can actually
	# get between them — a neck that the falloffs pinched shut leaves the far
	# half of the map unreachable, and nothing else here would notice.
	print("\ncan you get across")
	var ff := FlowField.new(cfg)
	var ms := ff.build(field.heights, Vector2i(int(GOAL.x), int(GOAL.y)))
	var reached := 0
	for isl in ISLANDS:
		var c: Vector2 = isl[0]
		if ff.is_reachable(int(c.x), int(c.y)):
			reached += 1
	_ok("every island is reachable from the far one", reached == ISLANDS.size(),
		"%d of %d, field built in %.0f ms" % [reached, ISLANDS.size(), ms])
	_ok("the landing site can reach the goal",
		ff.is_reachable(int(LANDING.x), int(LANDING.y)),
		"cost %.0f" % ff.cost_at_cell(int(LANDING.x), int(LANDING.y)))

	# The necks have to be narrow, or they are not chokepoints and putting the
	# ground in separate pieces bought nothing.
	var widest := 0
	var narrowest := 999
	for n in NECKS:
		var mid: Vector2 = (n[0] + n[1]) * 0.5
		var dir: Vector2 = (n[1] - n[0]).normalized()
		var across := Vector2(-dir.y, dir.x)
		var w := 0
		for step in range(-20, 21):
			if field.is_passable(mid + across * float(step)):
				w += 1
		widest = maxi(widest, w)
		narrowest = mini(narrowest, w)
	_ok("the necks are chokepoints", widest <= 16 and narrowest >= 3,
		"%d to %d metres of walkable width" % [narrowest, widest])

	print("\nwhat the ground is made of")
	var ground := 0
	for k in mats:
		ground += int(mats[k])
	for i in GroundMaterials.COUNT:
		var n := int(mats.get(i, 0))
		print("    %-10s %5d m2   %4.1f%%"
			% [GroundMaterials.NAMES[i], n, 100.0 * n / maxi(1, ground)])
	# The whole point of the material pass: the open flats must be the MAJORITY
	# of the walkable ground, and the root mat must be a border rather than a
	# carpet. Before this, the filament web covered everything.
	var open_pct := 100.0 * (int(mats.get(GroundMaterials.MOSS, 0))
		+ int(mats.get(GroundMaterials.LOAM, 0))) / maxi(1, ground)
	var vine_pct := 100.0 * int(mats.get(GroundMaterials.VINE, 0)) / maxi(1, ground)
	_ok("open ground is most of the map", open_pct > 45.0,
		"%.1f%% moss and loam" % open_pct)
	_ok("the root mat is a border, not a carpet", vine_pct > 8.0 and vine_pct < 32.0,
		"%.1f%% vine" % vine_pct)
	_ok("every material is actually used",
		mats.size() == GroundMaterials.COUNT, "%d of %d slots"
			% [mats.size(), GroundMaterials.COUNT])

	print("\nthe dressing")
	var placed := Dressing.place(field, plan, LANDING)
	var got := 0
	var short := PackedStringArray()
	for e in plan.entries:
		var n: int = placed.get(e.model, []).size()
		got += n
		# How much ground this rule is actually allowed to use. Without it, a
		# shortfall is indistinguishable between "the band is empty", "the
		# clearance is too wide" and "the clusters landed badly" — and on a map
		# where the land area just fell by two thirds, that guess is the whole
		# question.
		var legal := _legal_cells(field, e)
		var need := e.count * e.clearance_m * e.clearance_m * 1.4
		print("    %-16s %3d of %3d   %5d legal m2, needs about %5d"
			% [e.model, n, e.count, legal, int(need)])
		if n < e.count * 0.75:
			short.append("%s %d/%d" % [e.model, n, e.count])
	_ok("the scatter finds room for what it promised", short.is_empty(),
		"%d of %d props placed" % [got, plan.total_props()])

	# Nothing hanging in the cloud, nothing on top of the player.
	var on_landing := 0
	var floating := 0
	var rimmed := 0
	for model in placed:
		for t in placed[model]:
			var p := Vector2(t.origin.x, t.origin.z)
			if p.distance_to(LANDING) < plan.landing_clear_m:
				on_landing += 1
			var h := field.height_at(p)
			if h < VOID_BELOW:
				floating += 1
			elif h < cfg.impassable_below:
				rimmed += 1
	_ok("nothing grows on the landing site", on_landing == 0,
		"%.0f m clear" % plan.landing_clear_m)
	_ok("nothing is left hanging in the cloud", floating == 0,
		"%d below the world edge" % floating)
	# The roots ARE the island edges in the reference, so a bare rim means the
	# banding is wrong even though every other check passes.
	_ok("the rims are rooted", rimmed > 40,
		"%d props on the cliff edge" % rimmed)

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


## The material slots, for tools/paint_preview.py. Same numbers the shader gets.
func _material_json() -> Array:
	var out := []
	for m in _materials():
		out.append({
			"name": m.display_name,
			"colour": m.colour.to_html(false),
			"colour_alt": m.colour_alt.to_html(false),
			"vein": m.vein_strength, "stroke": m.stroke_scale_mult,
		})
	return out


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

	TerrainBuilder.classify_materials(field, VOID_BELOW)
	var mat := FileAccess.open(OUT + "/biodome_01_mat.u8", FileAccess.WRITE)
	mat.store_buffer(field.material_id)
	mat.close()

	var wet := FileAccess.open(OUT + "/biodome_01_water.r32", FileAccess.WRITE)
	for w in field.water:
		wet.store_float(w)
	wet.close()

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
	var cloud := _clouds()
	var meta := FileAccess.open(OUT + "/biodome_01.json", FileAccess.WRITE)
	meta.store_string(JSON.stringify({
		"cells_x": cfg.cells_x, "cells_z": cfg.cells_z,
		"height_scale_m": cfg.height_scale_m,
		"impassable_below": cfg.impassable_below, "rough_below": cfg.rough_below,
		"landing": [LANDING.x, LANDING.y],
		"void_below": VOID_BELOW,
		"grid_spacing_m": pal.grid_spacing_m,
		"clouds": {
			"height_m": cloud.height_m, "extent_m": cloud.extent_m,
			"lit": cloud.lit_colour.to_html(false),
			"shadow": cloud.shadow_colour.to_html(false),
			"deep": cloud.deep_colour.to_html(false),
			"horizon": cloud.horizon_colour.to_html(false),
			"scale": cloud.cloud_scale, "coverage": cloud.coverage,
			"softness": cloud.softness,
		},
		# Exported so tools/paint_preview.py reads the SAME numbers the shader
		# gets. It used to keep its own copy and they drifted within an hour.
		"paint": {
			"strength": pal.paint_strength, "bands": pal.paint_bands,
			"stroke_scale": pal.stroke_scale, "stroke_stretch": pal.stroke_stretch,
			"stroke_depth": pal.stroke_depth, "quantise": pal.paint_quantise,
			"edge_ink": pal.edge_ink, "tone": pal.paint_tone,
			"canvas_grain": pal.canvas_grain,
			"ink_strength": pal.ink_strength,
			"ink_colour": pal.ink_colour.to_html(false),
			"ink_silhouette": pal.ink_silhouette, "ink_crease": pal.ink_crease,
		},
		"surface": {
			"macro_scale": pal.macro_scale, "macro_strength": pal.macro_strength,
			"striation": pal.striation_strength, "vein_scale": pal.vein_scale,
			"vein_sharpness": pal.vein_sharpness, "vein_strength": pal.vein_strength,
			"pool_glow_strength": pal.pool_glow_strength,
			"pool_alt_mix": pal.pool_alt_mix, "grid_strength": pal.grid_strength,
		},
		"materials": _material_json(),
		"palette": {
			"pool": pal.col_pool.to_html(false), "rough": pal.col_rough.to_html(false),
			"ground": pal.col_ground.to_html(false), "ridge": pal.col_ridge.to_html(false),
			"cliff": pal.col_cliff.to_html(false),
			"pool_glow": pal.pool_glow.to_html(false),
			"pool_glow_alt": pal.pool_glow_alt.to_html(false),
			"pool_glow_strength": pal.pool_glow_strength,
			"vein_glow": pal.vein_glow.to_html(false),
		},
		"props": props,
	}, "  "))
	meta.close()
	print("\n  wrote   %s/biodome_01.r32   %d x %d float32" % [OUT, cfg.cells_x, cfg.cells_z])
	print("  wrote   %s/biodome_01.json  %d prop kinds" % [OUT, props.size()])


## Square metres of ground this scatter rule may legally stand on.
func _legal_cells(field: Heightfield, e: PropScatter) -> int:
	var cfg := field.cfg
	var n := 0
	for z in cfg.cells_z:
		for x in cfg.cells_x:
			var h := field.heights[z * cfg.cells_x + x]
			if h < e.height_min or h > e.height_max:
				continue
			if Dressing.slope_at(field, Vector2(x, z)) > e.max_slope:
				continue
			n += 1
	return n
