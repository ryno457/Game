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
## TRACED FROM THE REFERENCE, not approximated.
##
## The outline below is the red line drawn over the reference image, read off in
## normalised map coordinates and converted here. Discs cannot follow a
## silhouette somebody drew by hand — approximating a coastline with circles
## reads as a row of bubbles — so the mass is a POLYGON fill and the lobes sit
## on top of it.
##
## Everything in this block is positioned as a fraction of the map frame, which
## is how it was measured off the image. Change the map size and it still lands
## in the right place.
const OUTLINE_UV := [
	Vector2(0.030, 0.420), Vector2(0.020, 0.300), Vector2(0.065, 0.110),
	Vector2(0.170, 0.030), Vector2(0.265, 0.045), Vector2(0.315, 0.095),
	# THE TOP NOTCH. Traced with five points, not one: a single vertex makes a
	# narrow V that the polygon's own shoulder fills straight back in, and the
	# first pass came out as a shallow dent instead of a bay. It runs from
	# about u 0.36 to 0.62 and bottoms out near u 0.44.
	Vector2(0.360, 0.160), Vector2(0.400, 0.245), Vector2(0.440, 0.272),
	Vector2(0.490, 0.215), Vector2(0.545, 0.145), Vector2(0.605, 0.080),
	Vector2(0.700, 0.070), Vector2(0.800, 0.115), Vector2(0.875, 0.195),
	Vector2(0.930, 0.325), Vector2(0.948, 0.480), Vector2(0.922, 0.625),
	Vector2(0.880, 0.750), Vector2(0.818, 0.850), Vector2(0.730, 0.912),
	Vector2(0.630, 0.942), Vector2(0.540, 0.920),
	# THE BOTTOM NOTCH, offset west of the top one — which is what makes the
	# waist run diagonally rather than straight across.
	Vector2(0.478, 0.868), Vector2(0.437, 0.812), Vector2(0.400, 0.778),
	Vector2(0.362, 0.818), Vector2(0.318, 0.872),
	Vector2(0.255, 0.912), Vector2(0.168, 0.920), Vector2(0.088, 0.868),
	Vector2(0.048, 0.758), Vector2(0.030, 0.600),
]

const PLATE_LEVEL := 0.50
## Anything under this is a channel between lobes rather than a lobe top.
const CHANNEL_BELOW := 0.545
## How thin the channel strands are. Higher is thinner.
const WEB := 0.84
## Ground below this is not drawn at all.
const VOID_BELOW := 0.16

## The two plateaus circled on the reference, and the rest of the lobe layout
## read off the same image. u, v, radius in metres, top height.
const LOBE_UV := [
	# CIRCLED: the upper-left plateau, the one with the bridge on it. This is
	# where the module comes down.
	[Vector2(0.300, 0.190), 17.0, 0.74],
	# CIRCLED: the lower-right plateau. The far end of the path.
	[Vector2(0.700, 0.620), 18.0, 0.72],
	[Vector2(0.150, 0.500), 14.0, 0.67],
	[Vector2(0.300, 0.620), 15.0, 0.68],
	[Vector2(0.720, 0.280), 16.0, 0.70],
	[Vector2(0.880, 0.450), 14.0, 0.66],
	[Vector2(0.800, 0.810), 15.0, 0.68],
	[Vector2(0.170, 0.790), 13.0, 0.67],
]

## THE OPEN AREA IN THE MIDDLE, which is water. The reference has the cave and
## its two glowing pools here; the note was to make the whole middle open water.
const WATER_UV := Vector2(0.535, 0.510)
const WATER_R := 15.0

## THE PATH from the top plateau to the bottom one, routed around the west side
## of the water and along under it — the way the reference's ground runs.
const PATH_UV := [
	Vector2(0.300, 0.190), Vector2(0.322, 0.300), Vector2(0.345, 0.420),
	Vector2(0.362, 0.530), Vector2(0.390, 0.640), Vector2(0.455, 0.720),
	Vector2(0.560, 0.762), Vector2(0.650, 0.706), Vector2(0.700, 0.620),
]

var _uv_scale := Vector2(150.0, 112.0)


## Map-frame fraction to metres. Everything above is measured off the image in
## fractions, so this is the one place the map's size enters.
func _uv(p: Vector2) -> Vector2:
	return Vector2(p.x * _uv_scale.x, p.y * _uv_scale.y)


func _landing() -> Vector2:
	return _uv(LOBE_UV[0][0])


func _goal() -> Vector2:
	return _uv(LOBE_UV[1][0])

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
	m.noise_seed = 20260916
	m.base_level = 0.055
	m.amplitude = 0.10
	m.octaves = [Vector2(0.045, 0.58), Vector2(0.125, 0.30), Vector2(0.29, 0.12)]
	m.spawn = _landing()
	m.goal = _goal()

	var ops: Array[Dictionary] = []

	# 1. THE MASS, as one polygon traced off the reference. One op, not fifteen
	# discs — and the notches top and bottom come for free because they are part
	# of the outline rather than something bitten out afterwards.
	var poly := []
	for uv in OUTLINE_UV:
		poly.append(_uv(uv))
	# TWO passes over the same outline, and the pair is what makes a cliff.
	#
	# One pass gives a single shoulder, and its width is a straight trade
	# against how sharply the notches cut: tight enough for crisp bays left the
	# drawn-but-unwalkable rim at 3% and it stopped reading as a cliff.
	#
	# So: a wide shallow LEDGE first, holding at rim height well past the
	# outline, then the plate raised on top of it with a tight shoulder. The
	# band between them is the cliff face, and the bays stay sharp.
	ops.append({"op": "polygon", "points": poly,
		"level": 0.215, "edge": 11.0, "strength": 1.0})
	ops.append({"op": "polygon", "points": poly,
		"level": PLATE_LEVEL, "edge": 3.0, "strength": 0.98})

	# 2. THE PATH, before the lobes so the lobes sit on top of where it lands.
	# Raised just above the plate, so it reads as a route rather than a wall,
	# and wide enough for a convoy.
	var path := []
	for uv in PATH_UV:
		path.append(_uv(uv))
	_run(ops, path, 6.0, 0.575, 0.85, 2.0)

	# 3. THE LOBES — the "different heights". Raised on the plate, so the plate
	# shows between them as lower channels where the root mat lives.
	for d in LOBE_UV:
		var c := _uv(d[0])
		ops.append({"op": "plateau", "x": c.x, "z": c.y,
			"r": d[1], "level": d[2], "strength": 0.93})
	for d in LOBE_UV:
		var c := _uv(d[0])
		ops.append({"op": "plateau", "x": c.x, "z": c.y,
			"r": float(d[1]) * 0.66, "level": float(d[2]) - 0.02, "strength": 0.86})

	# 4. Exposed rock at a few rims, as the reference shows.
	for r in [[Vector2(0.09, 0.22), 8.0, 0.88], [Vector2(0.86, 0.18), 8.0, 0.89],
			[Vector2(0.90, 0.86), 8.0, 0.86], [Vector2(0.10, 0.84), 7.0, 0.87]]:
		var c := _uv(r[0])
		ops.append({"op": "plateau", "x": c.x, "z": c.y,
			"r": r[1], "level": r[2], "strength": 0.78})

	# 5. THE OPEN MIDDLE, as water. Banked wide and shallow first, then cut
	# deep inside, so there is a shoreline to stand on rather than a kerb — and
	# so the path down the west side of it stays walkable.
	var wc := _uv(WATER_UV)
	ops.append({"op": "plateau", "x": wc.x, "z": wc.y,
		"r": WATER_R + 7.0, "level": 0.355, "strength": 0.70})
	ops.append({"op": "plateau", "x": wc.x, "z": wc.y,
		"r": WATER_R, "level": 0.155, "strength": 0.95, "water": true})

	# 6. Smaller pools out on the lobes, so the water is not all in one place.
	for b in [[Vector2(0.155, 0.255), 5.0, 0.19], [Vector2(0.780, 0.230), 4.5, 0.18],
			[Vector2(0.840, 0.800), 4.5, 0.19]]:
		var c := _uv(b[0])
		ops.append({"op": "plateau", "x": c.x, "z": c.y,
			"r": float(b[1]) + 4.5, "level": 0.32, "strength": 0.62})
		ops.append({"op": "plateau", "x": c.x, "z": c.y,
			"r": b[1], "level": b[2], "strength": 0.95, "water": true})

	# 7. The landing clearing, on the upper-left circled plateau.
	var land := _landing()
	ops.append({"op": "plateau", "x": land.x, "z": land.y,
		"r": 10.0, "level": 0.62, "strength": 0.90})
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
	p.channel_below = CHANNEL_BELOW
	p.channel_web_threshold = WEB
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
		# The roots. Banded 0.18-0.56 so they cover the cliff rim AND the
		# channels between the lobes — which is where the reference puts them.
		# Banded to the rim alone there was only 1457 legal square metres and
		# the scatter could place 98 of 130.
		_entry("flora_tendril", 140, 0.180, 0.56, 0.62, 2.2, 1.00, 2.20, 0.55,
			18, 15.0, false),
		# Coral stays at the waterlines and the rim, as it does in the
		# reference — it is a shoreline thing, not a channel thing.
		_entry("flora_coral", 55, 0.185, 0.40, 0.55, 1.8, 0.95, 1.85, 0.35,
			12, 12.0, false),
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
	var mats := TerrainBuilder.classify_materials(field, VOID_BELOW, CHANNEL_BELOW, WEB)
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
	# These bounds were written for an archipelago and the archipelago was a
	# misreading. The reference is mostly LAND: void appears only around the
	# outline and in the two notches. The lower bound still guards against the
	# map filling the frame edge to edge, which would lose the silhouette
	# entirely — and the silhouette itself is checked directly further down.
	_ok("there is void around the outline",
		drawn > total * 0.55 and drawn < total * 0.88,
		"%.1f%% is ground" % pct.call(drawn))
	_ok("and the ground is mostly walkable", walkable > drawn * 0.55,
		"%.1f%% of the map, %.1f%% of the ground"
			% [pct.call(walkable), 100.0 * walkable / maxi(1, drawn)])
	# The rim is what stops an island looking like a cut-out: real ground you
	# can see but not stand on, between the walkable top and the drop.
	# The rim is the cliff the mass falls away over. It comes from the polygon's
	# shoulder, so it is directly traded against how sharply the notches cut:
	# tightening the shoulder to 3.5 m to keep the bays crisp thinned the rim to
	# 3% and it stopped reading as a cliff at all.
	_ok("the mass has a cliff rim", rim > total * 0.04,
		"%.1f%% drawn but unwalkable" % pct.call(rim))

	# The landing site.
	_ok("the landing site is on ground", field.is_passable(_landing()),
		"height %.2f at %.0f, %.0f" % [field.height_at(_landing()), _landing().x, _landing().y])
	var slope_here := Dressing.slope_at(field, _landing())
	_ok("and flat enough to build on", slope_here < 0.12, "slope %.3f" % slope_here)

	# THE CHECK THAT MATTERS. The islands are only a design if you can actually
	# get between them — a neck that the falloffs pinched shut leaves the far
	# half of the map unreachable, and nothing else here would notice.
	print("\nis it ONE landmass")
	var ff := FlowField.new(cfg)
	var ms := ff.build(field.heights, Vector2i(int(_goal().x), int(_goal().y)))

	# The correction that prompted this rebuild: the reference is one connected
	# mass with pieces cut out, not an archipelago. So the test is CONNECTEDNESS
	# — every walkable cell must be reachable from the far side, not merely
	# "each island has a bridge". A stray pocket cut off by a bay would pass the
	# old check and fail this one.
	var walkable_cells := 0
	var reachable := 0
	for z in cfg.cells_z:
		for x in cfg.cells_x:
			if field.heights[z * cfg.cells_x + x] < cfg.impassable_below:
				continue
			walkable_cells += 1
			if ff.is_reachable(x, z):
				reachable += 1
	var connected := 100.0 * reachable / maxi(1, walkable_cells)
	_ok("the walkable ground is one piece", connected > 97.0,
		"%.1f%% of %d walkable cells reachable, field in %.0f ms"
			% [connected, walkable_cells, ms])
	if connected <= 97.0:
		# A severed map is nearly impossible to debug from a percentage. This
		# is how the first break was found: the mass LOOKED continuous and the
		# waist was sitting between void_below and impassable_below — drawn
		# ground nothing could walk on.
		_print_ascii(field)

	var lobes_ok := 0
	for d in LOBE_UV:
		# _uv, not d[0]. The lobe table is in map-frame FRACTIONS — testing
		# (0.30, 0.19) as if it were metres asks about a cell in the far corner
		# and every lobe came back unreachable.
		var c := _uv(d[0])
		if ff.is_reachable(int(c.x), int(c.y)):
			lobes_ok += 1
	_ok("every lobe is reachable", lobes_ok == LOBE_UV.size(),
		"%d of %d" % [lobes_ok, LOBE_UV.size()])
	_ok("the landing site can reach the far side",
		ff.is_reachable(int(_landing().x), int(_landing().y)),
		"cost %.0f" % ff.cost_at_cell(int(_landing().x), int(_landing().y)))

	# THE SILHOUETTE. The outline was traced off the reference, so the test is
	# whether the ground actually follows it: a point nudged inward from each
	# traced vertex must be ground, and one nudged outward must be void. That
	# is a much stronger claim than "some bays exist" — it checks the shape.
	var poly := PackedVector2Array()
	for uv in OUTLINE_UV:
		poly.append(_uv(uv))
	var centre := Vector2.ZERO
	for p2 in poly:
		centre += p2
	centre /= float(poly.size())

	var inside_ok := 0
	var outside_ok := 0
	for p2 in poly:
		var inward: Vector2 = p2 + (centre - p2).normalized() * 7.0
		var outward: Vector2 = p2 - (centre - p2).normalized() * 7.0
		if field.height_at(inward) >= VOID_BELOW:
			inside_ok += 1
		outward.x = clampf(outward.x, 0.0, cfg.cells_x - 1.0)
		outward.y = clampf(outward.y, 0.0, cfg.cells_z - 1.0)
		if field.height_at(outward) < VOID_BELOW:
			outside_ok += 1
	_ok("the mass fills the traced outline", inside_ok >= poly.size() - 1,
		"%d of %d vertices have ground just inside them" % [inside_ok, poly.size()])
	_ok("and stops at it", outside_ok >= poly.size() - 4,
		"%d of %d have void just outside" % [outside_ok, poly.size()])

	# The two circled plateaus, and the path between them. This is the thing
	# that was asked for by name, so it is checked by name.
	var top := _landing()
	var bottom := _goal()
	_ok("the two circled plateaus are ground",
		field.is_passable(top) and field.is_passable(bottom),
		"top %.2f, bottom %.2f" % [field.height_at(top), field.height_at(bottom)])
	var path_blocked := 0
	var path_steps := 0
	for i in PATH_UV.size() - 1:
		var pa := _uv(PATH_UV[i])
		var pb := _uv(PATH_UV[i + 1])
		var n := maxi(1, int(pa.distance_to(pb)))
		for k in n + 1:
			path_steps += 1
			if not field.is_passable(pa.lerp(pb, float(k) / n)):
				path_blocked += 1
	_ok("the path connects top to bottom", path_blocked == 0,
		"%d of %d metres walkable" % [path_steps - path_blocked, path_steps])

	# The middle is open water, which is the other thing asked for by name.
	var wc := _uv(WATER_UV)
	_ok("the middle is water", field.height_at(wc) < cfg.impassable_below
			and field.water[int(wc.y) * cfg.cells_x + int(wc.x)] > 0.5,
		"height %.2f, water mask %.2f"
			% [field.height_at(wc), field.water[int(wc.y) * cfg.cells_x + int(wc.x)]])

	# And the lobes have to sit ABOVE the channels between them, or "different
	# heights" is a claim the map does not make.
	#
	# MEDIAN over the lobe's inner area, not the height at its centre point.
	# Three lobes have a pool on them, and a single centre sample was reading
	# the bottom of the pond and calling the whole lobe low. The median is
	# strictly more informative: it is not hostage to whichever op happened to
	# land on one cell.
	var lowest_lobe := 1.0
	var lowest_name := ""
	for d in LOBE_UV:
		var c := _uv(d[0])
		var r: float = float(d[1]) * 0.6
		var samples := PackedFloat32Array()
		for z in range(int(c.y - r), int(c.y + r) + 1):
			for x in range(int(c.x - r), int(c.x + r) + 1):
				if Vector2(x - c.x, z - c.y).length() > r:
					continue
				if x < 0 or x >= cfg.cells_x or z < 0 or z >= cfg.cells_z:
					continue
				samples.append(field.heights[z * cfg.cells_x + x])
		if samples.is_empty():
			continue
		samples.sort()
		var med: float = samples[samples.size() / 2]
		if med < lowest_lobe:
			lowest_lobe = med
			lowest_name = "%.0f, %.0f" % [c.x, c.y]
	_ok("the lobes stand above the channels", lowest_lobe > PLATE_LEVEL + 0.06,
		"lowest lobe median %.2f (at %s) against a %.2f plate"
			% [lowest_lobe, lowest_name, PLATE_LEVEL])

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
	var placed := Dressing.place(field, plan, _landing())
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
			if p.distance_to(_landing()) < plan.landing_clear_m:
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
	# A bare rim means the banding is wrong even when every other check passes,
	# so this floor stays — but it moved from 40 to 25 when the roots stopped
	# being rim-only. They now cover the channels between the lobes as well,
	# which is where the reference puts them, so a smaller share of the same
	# props lands on the rim. The floor is about the rim not being EMPTY.
	_ok("the rims are rooted", rimmed > 25,
		"%d props on the cliff edge" % rimmed)

	var again := Dressing.place(TerrainBuilder.build(map), plan, _landing())
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

	TerrainBuilder.classify_materials(field, VOID_BELOW, CHANNEL_BELOW, WEB)
	var mat := FileAccess.open(OUT + "/biodome_01_mat.u8", FileAccess.WRITE)
	mat.store_buffer(field.material_id)
	mat.close()

	var wet := FileAccess.open(OUT + "/biodome_01_water.r32", FileAccess.WRITE)
	for w in field.water:
		wet.store_float(w)
	wet.close()

	var placed := Dressing.place(field, plan, _landing())
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
		"landing": [_landing().x, _landing().y],
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


## The map as text: '#' walkable, ':' drawn but not walkable, ' ' void.
##
## Printed only when connectivity fails. A percentage cannot tell you WHERE a
## map got severed, and this can — at a glance.
func _print_ascii(field: Heightfield) -> void:
	var cfg := field.cfg
	print("      (# walkable   : drawn but impassable   . void)")
	for z in range(0, cfg.cells_z, 3):
		var row := ""
		for x in range(0, cfg.cells_x, 2):
			var h := field.heights[z * cfg.cells_x + x]
			row += "." if h < VOID_BELOW else (":" if h < cfg.impassable_below else "#")
		print("  %3d %s" % [z, row])
