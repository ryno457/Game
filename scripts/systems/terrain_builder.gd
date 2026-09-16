class_name TerrainBuilder
extends RefCounted
## Turns a TerrainMap into a Heightfield, deterministically.
##
## Same input always gives the same field — no RandomNumberGenerator state
## leaks between ops, and the noise is a pure function of cell coordinates.
## That is what lets a test map be a stable fixture rather than a moving
## target, and what makes "seed + diff" a viable save format.

# Sampling density for bake_shade(). These are ALGORITHM parameters, not art:
# they buy accuracy, not a look, and the art-facing reach and gain knobs live in
# BiomePalette where the project rule puts them. Raise AO_DIRS to 16 if a still
# frame ever shows an eight-fold star around a lone spire; the cost is linear.
const AO_DIRS := 8
const AO_STEPS := 6
const SHADOW_STEPS := 12
# Distant blockers cast fainter shadows. This is the 1/(1+t*k) term that makes
# a near rock's shadow crisp and a far ridge's shadow a faint wash, which is
# what an area light does and what a paint program's Size slider approximates.
const SHADOW_DISTANCE_FADE := 0.06
## The physical range the wide-curvature channel is encoded over, before
## companding. Measured off this map: |curvature| has a p99 of 2.02 and a p100
## of 3.04, so 3.0 clips 0.03% of cells instead of the 23.5% that applying the
## art gain before the clamp used to.
const CURV_RANGE := 3.0


static func build(map: TerrainMap) -> Heightfield:
	var cfg := map.terrain
	var hf := Heightfield.new(cfg)
	var s := Vector2i(cfg.cells_x, cfg.cells_z)

	var base: float = map.base_level if map.base_level >= 0.0 else cfg.neutral_height
	for z in s.y:
		for x in s.x:
			var n := 0.0
			for o in map.octaves:
				n += _vnoise(x * o.x, z * o.x, map.noise_seed) * o.y
			hf.heights[z * s.x + x] = clampf(
				base + (n - 0.5) * map.amplitude, cfg.clamp_min, cfg.clamp_max)

	for op in map.ops:
		_apply(hf, op)
	return hf


static func _apply(hf: Heightfield, op: Dictionary) -> void:
	match String(op.get("op", "")):
		"crater":
			hf.deform(Vector2(op.x, op.z), op.r, op.amount)
		"trench":
			var a := Vector2(op.x0, op.z0)
			var b := Vector2(op.x1, op.z1)
			var steps := maxi(1, int(a.distance_to(b)))
			for i in steps + 1:
				hf.deform(a.lerp(b, float(i) / steps), op.r, op.amount)
		"plateau":
			_disc(hf, Vector2(op.x, op.z), op.r, op.level,
				float(op.get("strength", 1.0)))
			# A plateau op marked "water" also stamps the water mask, which is
			# how the shader tells a pool from the outer rim of an island —
			# they sit in the same height band and nothing about a single cell
			# distinguishes them.
			if bool(op.get("water", false)):
				_mark_water(hf, Vector2(op.x, op.z), op.r)
		"band":
			_rect(hf, Rect2(op.x0, op.z0, op.x1 - op.x0, op.z1 - op.z0),
				op.level, float(op.get("edge", 4.0)))
		"polygon":
			# A traced outline, filled. Discs cannot follow a silhouette that
			# was drawn by hand — you end up approximating a coastline with
			# circles and it reads as a row of bubbles. This takes the points
			# straight off the reference.
			_polygon(hf, op.points, op.level, float(op.get("edge", 5.0)),
				float(op.get("strength", 1.0)))
		_:
			push_warning("TerrainBuilder: unknown op '%s'" % op.get("op", ""))


## Distance from every cell to the three things the shading ramps off.
##
## Packed as one RGB8 texture, one byte per channel:
##   R  distance to the EDGE of the mass (where the ground runs out)
##   G  distance to the nearest ROOT STRAND
##   B  distance to the nearest WATERLINE
##
## This is the input that makes painted gradients possible at all. Almost every
## gradient in the reference is a distance rather than a height: ground darkens
## as it nears the edge, lightens away from a strand, pales toward a shoreline.
## Two places at the same height shade differently depending on how far they are
## from a feature, and a height ramp simply cannot say that — which is why the
## banded version looks flat.
##
## Baked at load. The fields change when the player digs, but only near the dig,
## and a full transform is ~57 ms so a local rebake is the shape of that fix.
static func bake_fields(hf: Heightfield, void_below: float,
		range_m: float = 20.0, strand_range_m: float = 4.0) -> PackedByteArray:
	var cfg := hf.cfg
	var n := cfg.cells_x * cfg.cells_z

	var edge := PackedByteArray()
	var strand := PackedByteArray()
	var shore := PackedByteArray()
	edge.resize(n)
	strand.resize(n)
	shore.resize(n)
	for i in n:
		edge[i] = 1 if hf.heights[i] < void_below else 0
		strand[i] = 1 if hf.material_id[i] == GroundMaterials.VINE else 0
		shore[i] = 1 if hf.water[i] > 0.05 else 0

	# The strand channel is SIGNED, and that is the whole difference between a
	# root that reads as a tube and one that reads inside-out.
	#
	# Unsigned, every cell of the root mat itself is distance ZERO — 16% of this
	# map sat at exactly 0. The shader's tube then got t = 0, crest = 1 and a
	# gradient of (0,0) across the entire interior, so it flattened the whole mat
	# to face straight up and put the only tilt in a pinched ring at the rim:
	# a mesa, not a tube. `strand_shade` compounded it, darkening the interior at
	# full strength because exp(-0) is 1.
	#
	# Signed, the mat has an inside. Distance runs to zero at its edge and grows
	# negative toward its centreline, which is exactly the coordinate a circular
	# cross-section needs.
	var inv := PackedByteArray()
	inv.resize(n)
	for i in n:
		inv[i] = 1 - strand[i]

	var d_edge := DistanceField.compute(edge, cfg.cells_x, cfg.cells_z, range_m)
	var d_shore := DistanceField.compute(shore, cfg.cells_x, cfg.cells_z, range_m)
	var d_out := DistanceField.compute(strand, cfg.cells_x, cfg.cells_z, strand_range_m)
	var d_in := DistanceField.compute(inv, cfg.cells_x, cfg.cells_z, strand_range_m)

	var out := PackedByteArray()
	out.resize(n * 3)
	for i in n:
		# A SHORT range for the strand, on its own scale rather than the shared
		# 20 m. At 20 m a 1.8 m tube spans about 23 of the 256 codes, so the one
		# feature the channel exists to make smooth was being banded by its own
		# encoding.
		var signed_d := d_out[i] - d_in[i]
		out[i * 3] = int(clampf(d_edge[i] / range_m, 0.0, 1.0) * 255.0)
		out[i * 3 + 1] = int(clampf(signed_d / (2.0 * strand_range_m) + 0.5,
			0.0, 1.0) * 255.0)
		out[i * 3 + 2] = int(clampf(d_shore[i] / range_m, 0.0, 1.0) * 255.0)
	return out


## Decide what every cell is MADE OF, from the finished heightfield.
##
## Run after the ops, not during them: a material depends on the shape the ops
## left behind — how steep it ended up, how close it is to water, how close to
## the edge of the world — and none of that is known while they are still being
## applied.
##
## Rules are applied in order and later ones win. The root mat is last because
## in the reference it runs over everything at a plateau's rim, cliffs included.
## `rim_m` is the width of the root mat, and it is the most sensitive number
## here. At 5 m on plateaus 20 m across the mat covered HALF the walkable
## ground and bare rock never appeared at all, because the mat is applied last
## and overrode it. A border is a couple of metres.
## `channel_below` is the height that separates a raised lobe from the plate
## between lobes. Ground at or under it is CHANNEL, and in the reference the
## root mat lives down in the channels as much as around the outer rim — it is
## the web that fills every gap between the plateaus. Zero disables it, which
## is what a map with no lobes wants.
static func classify_materials(hf: Heightfield, void_below: float,
		channel_below: float = 0.0,
		web_threshold: float = 0.82,
		rim_m: float = 2.5, shore_m: float = 3.0,
		strand_w_m: float = 5.0) -> Dictionary:
	var cfg := hf.cfg
	var w := cfg.cells_x
	var h := cfg.cells_z
	var counts := {}

	# Distance-to-edge, by dilation rather than by searching a radius per cell.
	# Two passes over the grid instead of sixteen thousand small searches.
	var near_edge := PackedByteArray()
	near_edge.resize(w * h)
	var near_water := PackedByteArray()
	near_water.resize(w * h)
	for z in h:
		for x in w:
			var i := z * w + x
			near_edge[i] = 1 if hf.heights[i] < void_below else 0
			near_water[i] = 1 if hf.water[i] > 0.05 else 0
	near_edge = _dilate(near_edge, w, h, int(rim_m))
	near_water = _dilate(near_water, w, h, int(shore_m))

	for z in h:
		for x in w:
			var i := z * w + x
			var height := hf.heights[i]
			if height < void_below:
				hf.material_id[i] = GroundMaterials.MOSS
				continue

			var id := GroundMaterials.MOSS
			# Broad patches of darker soil, so the flats are not one colour.
			if _vnoise(x * 0.035, z * 0.035, 7717) > 0.58:
				id = GroundMaterials.LOAM
			# Pale sediment where water has been, and in a NARROW band just
			# above the waterline. Keyed to rough_below it swallowed the whole
			# cliff band and became 40% of the map — sediment is a shoreline,
			# not a altitude.
			if near_water[i] == 1 or height < cfg.impassable_below + 0.05:
				id = GroundMaterials.SEDIMENT
			# Bare rock on anything steep, and on the tops of the ridges.
			if _slope(hf, x, z) > 0.35 or height > 0.72:
				id = GroundMaterials.ROCK
			# The root mat. Around the outer rim AND down in the channels
			# between the lobes — in the reference it is the web that fills
			# every gap, not merely an outline. Last, so it runs over the
			# cliffs and the bare rock the way it does there.
			# In the channels the mat is a WEB OF STRANDS with open ground
			# between them, not a fill. Filling every channel outright put the
			# root mat on 77% of the map — the opposite of the note that
			# started this, which was that not all the ground should be vines.
			#
			# Strands are a BAND AROUND A CONTOUR of a ridged noise fold, and
			# the band is measured in METRES, which is the whole trick.
			#
			# Thresholding the noise value directly — `ridge > 0.84` — was the
			# first attempt and it came out as scribble. The reason is that a
			# value threshold gives a band whose width is (value - threshold)
			# divided by the local GRADIENT, and that gradient varies by an
			# order of magnitude across the field: where the noise is steep the
			# strand is a hair, where it is flat the strand is a blob. Dividing
			# by the gradient cancels exactly that, so every strand comes out
			# the same width no matter where it lands — a root ribbon rather
			# than a contour line.
			var in_channel := false
			if channel_below > 0.0 and height < channel_below and strand_w_m > 0.0:
				var d := _ridge_dist(x, z, web_threshold)
				in_channel = d < strand_w_m * 0.5 / maxf(0.01, cfg.cell_size_m)
			if (near_edge[i] == 1 or in_channel) and hf.water[i] <= 0.05:
				id = GroundMaterials.VINE
			hf.material_id[i] = id
			counts[id] = int(counts.get(id, 0)) + 1
	return counts


## Grow a boolean mask outward by `steps` cells, separably.
static func _dilate(mask: PackedByteArray, w: int, h: int, steps: int) -> PackedByteArray:
	var src := mask
	for pass_i in maxi(1, steps):
		var dst := src.duplicate()
		for z in h:
			for x in w:
				if src[z * w + x] == 1:
					continue
				var hit := false
				var steps_4: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0),
					Vector2i(0, 1), Vector2i(0, -1)]
				for d in steps_4:
					var nx: int = x + d.x
					var nz: int = z + d.y
					if nx >= 0 and nx < w and nz >= 0 and nz < h and src[nz * w + nx] == 1:
						hit = true
						break
				if hit:
					dst[z * w + x] = 1
		src = dst
	return src


static func _slope(hf: Heightfield, x: int, z: int) -> float:
	var cfg := hf.cfg
	var sy := cfg.height_scale_m
	var xl := clampi(x - 1, 0, cfg.cells_x - 1)
	var xr := clampi(x + 1, 0, cfg.cells_x - 1)
	var zd := clampi(z - 1, 0, cfg.cells_z - 1)
	var zu := clampi(z + 1, 0, cfg.cells_z - 1)
	var dx := (hf.heights[z * cfg.cells_x + xl] - hf.heights[z * cfg.cells_x + xr]) * sy
	var dz := (hf.heights[zd * cfg.cells_x + x] - hf.heights[zu * cfg.cells_x + x]) * sy
	return 1.0 - clampf(Vector3(dx, 2.0, dz).normalized().y, 0.0, 1.0)


## Fill a closed polygon, with a soft shoulder outside it.
##
## Inside the outline the ground is pulled to `level`. Outside, it falls off
## over `edge` metres, so the mass has a cliff shoulder rather than a wall — the
## same profile a disc's cosine falloff gives, but following a drawn shape.
##
## Brute force against every segment: about thirty segments over sixteen
## thousand cells is half a million distance tests, which is nothing at build
## time and saves needing a polygon rasteriser.
static func _polygon(hf: Heightfield, points: Array, level: float,
		edge: float, strength: float) -> void:
	var cfg := hf.cfg
	var poly := PackedVector2Array()
	for p in points:
		poly.append(p)
	for z in cfg.cells_z:
		for x in cfg.cells_x:
			var p := Vector2(x, z)
			var d := _dist_to_poly(poly, p)
			var inside := Geometry2D.is_point_in_polygon(p, poly)
			# Inside: full strength. Outside: fade over `edge`.
			var f := 1.0 if inside else clampf(1.0 - d / maxf(0.001, edge), 0.0, 1.0)
			if f <= 0.0:
				continue
			# Squared, to match the shoulder shape the disc ops produce.
			var i := z * cfg.cells_x + x
			hf.heights[i] = lerpf(hf.heights[i], level,
				clampf(strength * f * f, 0.0, 1.0))


static func _dist_to_poly(poly: PackedVector2Array, p: Vector2) -> float:
	var best := 1.0e9
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		var ab := b - a
		var t := 0.0 if ab.length_squared() < 0.0001 \
			else clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
		best = minf(best, p.distance_to(a + ab * t))
	return best


## Paint the water mask over a disc, feathered at the rim so a shoreline fades
## rather than ending in a hard ring.
static func _mark_water(hf: Heightfield, c: Vector2, r: float) -> void:
	var cfg := hf.cfg
	var x0 := clampi(int(c.x - r), 0, cfg.cells_x - 1)
	var x1 := clampi(int(c.x + r), 0, cfg.cells_x - 1)
	var z0 := clampi(int(c.y - r), 0, cfg.cells_z - 1)
	var z1 := clampi(int(c.y + r), 0, cfg.cells_z - 1)
	for z in range(z0, z1 + 1):
		for x in range(x0, x1 + 1):
			var d := Vector2(x - c.x, z - c.y).length()
			if d > r:
				continue
			var i := z * cfg.cells_x + x
			hf.water[i] = maxf(hf.water[i], clampf(1.0 - d / r, 0.0, 1.0))


static func _disc(hf: Heightfield, c: Vector2, r: float, level: float, strength: float) -> void:
	var cfg := hf.cfg
	var x0 := clampi(int(c.x - r), 0, cfg.cells_x - 1)
	var x1 := clampi(int(c.x + r), 0, cfg.cells_x - 1)
	var z0 := clampi(int(c.y - r), 0, cfg.cells_z - 1)
	var z1 := clampi(int(c.y + r), 0, cfg.cells_z - 1)
	for z in range(z0, z1 + 1):
		for x in range(x0, x1 + 1):
			var d := Vector2(x - c.x, z - c.y).length()
			if d > r:
				continue
			var f: float = cos(d / r * PI * 0.5)
			var i := z * cfg.cells_x + x
			hf.heights[i] = lerpf(hf.heights[i], level, clampf(strength * f * f, 0.0, 1.0))


## Rect with a soft edge, so a rough band does not end in a cliff.
static func _rect(hf: Heightfield, r: Rect2, level: float, edge: float) -> void:
	var cfg := hf.cfg
	var x0 := clampi(int(r.position.x - edge), 0, cfg.cells_x - 1)
	var x1 := clampi(int(r.end.x + edge), 0, cfg.cells_x - 1)
	var z0 := clampi(int(r.position.y - edge), 0, cfg.cells_z - 1)
	var z1 := clampi(int(r.end.y + edge), 0, cfg.cells_z - 1)
	for z in range(z0, z1 + 1):
		for x in range(x0, x1 + 1):
			var inset := minf(
				minf(x - r.position.x, r.end.x - x),
				minf(z - r.position.y, r.end.y - z))
			var t := clampf((inset + edge) / maxf(0.001, edge * 2.0), 0.0, 1.0)
			if t <= 0.0:
				continue
			var i := z * cfg.cells_x + x
			hf.heights[i] = lerpf(hf.heights[i], level, t)


## Value noise. Pure function of (x, z, seed) — no generator state.
static func _vnoise(x: float, y: float, seed_v: int) -> float:
	var xi := floori(x)
	var yi := floori(y)
	var xf := x - xi
	var yf := y - yi
	var u := xf * xf * (3.0 - 2.0 * xf)
	var v := yf * yf * (3.0 - 2.0 * yf)
	return lerpf(
		lerpf(_hash(xi, yi, seed_v), _hash(xi + 1, yi, seed_v), u),
		lerpf(_hash(xi, yi + 1, seed_v), _hash(xi + 1, yi + 1, seed_v), u),
		v)


static func _hash(a: int, b: int, seed_v: int) -> float:
	var n: float = sin(a * 127.1 + b * 311.7 + seed_v * 0.013) * 43758.5453
	return n - floor(n)


## Bake the three SHAPE cues the painted look needs, into one RGB8 texture.
##
## R = ambient occlusion, G = cast shadow, B = wide-scale curvature.
##
## Why these three and why baked. A painted top-down map gets its form from
## three separate dark things, and the shader currently has none of them:
##
##   - OMNIDIRECTIONAL contact darkening where ground meets anything raised.
##     That is AO, and it is what stops a plateau floating above the plate.
##   - A DIRECTIONAL offset cast shadow, which is what tells the eye where the
##     light is. Photoshop's Drop Shadow layer style, as maths.
##   - CURVATURE, which is what makes a root read as a rounded tube rather than
##     a stripe, and a trench read as dug rather than as a dark patch.
##
## AO and the cast shadow are the expensive ones: a horizon sweep is ~40 taps
## per cell and the shadow march another 12, which is nothing per cell and
## ruinous per fragment (2.4 Mpix x 52 taps, every frame, on a phone with no
## measured headroom). So they are computed ONCE per cell here and read back as
## a single texture fetch in the shader.
##
## All three are derived from the live heightfield, so a dug trench gets correct
## AO, a correct cast shadow and a correct dug-looking rim the moment its chunk
## re-bakes. Nothing here is an offline bake against a "final" shape.
##
## Two things to know before wiring this to deformation:
##  - The dirty set must be DILATED by the AO reach and by the shadow length. A
##    crater darkens ground several metres outside itself.
##  - Godot 4 cannot update part of a texture (Zylann's heightmap plugin carries
##    the same note), so this must be one texture PER CHUNK. One biodome-wide
##    texture would mean re-uploading the whole map for every shovel-load.
static func bake_shade(hf: Heightfield, p: BiomePalette) -> PackedByteArray:
	var cfg := hf.cfg
	var w := cfg.cells_x
	var h := cfg.cells_z
	var hs := cfg.height_scale_m
	var tm := maxf(0.01, cfg.cell_size_m)
	var heights := hf.heights

	var out := PackedByteArray()
	out.resize(w * h * 3)

	# --- the sun, in heightmap space ----------------------------------------
	# Azimuth is measured clockwise from -Z (north on the minimap), so the
	# reference's upper-left light is azimuth -45 with a high elevation.
	var az := deg_to_rad(p.sun_azimuth_deg)
	var el := deg_to_rad(maxf(5.0, p.sun_elevation_deg))
	var ldir := Vector2(sin(az), -cos(az))
	# tan of the elevation, in HEIGHT UNITS per metre: the ray climbs this fast.
	var ltan := tan(el) / hs

	# --- AO sweep directions ------------------------------------------------
	# Eight azimuths, not sixteen. The visual difference at this reach is small
	# and the cost is linear in the count; sixteen is what to raise it to if a
	# still frame ever shows the eight-fold star.
	var dirs := PackedVector2Array()
	for i in AO_DIRS:
		var a := TAU * float(i) / float(AO_DIRS)
		dirs.append(Vector2(cos(a), sin(a)))

	# Step radii, geometric so a few steps reach a long way. r0 is one cell.
	# Geometric steps that ACTUALLY REACH ao_reach_m.
	#
	# This used to hardcode a 1.5x growth and stop after AO_STEPS, which capped
	# the sweep at 1 * 1.5^5 = 7.59 m no matter what the palette asked for.
	# ao_reach_m was a knob that did nothing above 7.6 — and the shipped bake
	# has an AO mean of 0.956, i.e. almost no occlusion anywhere. Solving for
	# the growth factor instead makes the number on the resource true.
	var radii := PackedFloat32Array()
	var reach := maxf(tm * 1.5, p.ao_reach_m)
	var grow: float = pow(reach / tm, 1.0 / float(maxi(1, AO_STEPS - 1)))
	var r := tm
	for _i in AO_STEPS:
		radii.append(r)
		r *= grow

	var shadow_radii := PackedFloat32Array()
	var s_reach := maxf(tm * 1.5, p.shadow_reach_m)
	var s_grow: float = pow(s_reach / tm, 1.0 / float(maxi(1, SHADOW_STEPS - 1)))
	r = tm
	for _i in SHADOW_STEPS:
		shadow_radii.append(r)
		r *= s_grow

	var soft := maxf(0.01, p.shadow_softness_m) / hs
	var curv_px := maxi(1, int(round(maxf(tm, p.curv_wide_m) / tm)))

	for z in h:
		for x in w:
			var i := z * w + x
			var hc := heights[i]

			# --- AO: how much of the sky this cell can see ------------------
			# For each azimuth, find the highest horizon angle anything in that
			# direction subtends, then weight by sin^2 for a cosine hemisphere.
			var occ := 0.0
			for d in dirs:
				var tan_h := 0.0
				for rr in radii:
					var sx := x + d.x * rr / tm
					var sz := z + d.y * rr / tm
					var hsamp := _h_at(heights, w, h, sx, sz, hc)
					tan_h = maxf(tan_h, (hsamp - hc) * hs / rr)
				var sin_h := tan_h / sqrt(1.0 + tan_h * tan_h)
				occ += sin_h * sin_h
			var ao := clampf(1.0 - occ / float(dirs.size()), 0.0, 1.0)

			# --- cast shadow: march back along the light --------------------
			# max(), not sum: it keeps the penumbra ramp monotonic, so the
			# shadow edge is a clean gradient with no ringing from the steps.
			var blocked := 0.0
			for rr in shadow_radii:
				# TOWARD the sun. This was a minus, marching away from it, so
				# nothing on the map was ever shadowed — and nothing on screen
				# said so, because the AO ring around every raised thing already
				# looks like a shadow. tools/shade_check.gd is what found it.
				var sx2 := x + ldir.x * rr / tm
				var sz2 := z + ldir.y * rr / tm
				var hsamp2 := _h_at(heights, w, h, sx2, sz2, hc)
				# Height the sun ray has reached by here. Anything above it
				# blocks, and by how much decides how dark.
				var need := hc + ltan * rr
				var far := 1.0 / (1.0 + rr * SHADOW_DISTANCE_FADE)
				blocked = maxf(blocked, far * (hsamp2 - need) / soft)
			var shadow := clampf(1.0 - clampf(blocked, 0.0, 1.0), 0.0, 1.0)

			# --- wide curvature ---------------------------------------------
			# Discrete Laplacian at a few cells' spacing. Negative is convex (a
			# crest), positive is concave (a crease). Stored biased so 0.5 is
			# flat, because the texture is unsigned.
			var lap := (_h_at(heights, w, h, x - curv_px, z, hc)
				+ _h_at(heights, w, h, x + curv_px, z, hc)
				+ _h_at(heights, w, h, x, z - curv_px, hc)
				+ _h_at(heights, w, h, x, z + curv_px, hc)
				- 4.0 * hc)
			# RAW curvature, companded — no art gain applied here.
			#
			# Multiplying by curv_gain BEFORE the 8-bit clamp railed 23.5% of
			# this map: 11.1% pinned at 0 and 12.4% at 255. That clip contour is
			# a hard C0 edge running through a quarter of the ground, and it fed
			# both the crease ink in pigment and the ramp bias in light() — a
			# manufactured band, in the one change whose whole purpose was
			# removing bands. The gain belongs in the shader, where it is a look
			# and not a quantisation.
			#
			# The compander is a signed square root. Curvature is near zero
			# almost everywhere (median 0.11 against a p100 of 3.04), so a linear
			# encode over a range wide enough not to clip spends five codes on
			# the values that cover half the map. sqrt spends about twenty-four.
			var raw := lap * hs / (float(curv_px) * tm)
			var curv := signf(raw) * sqrt(minf(absf(raw) / CURV_RANGE, 1.0))

			out[i * 3] = int(ao * 255.0)
			out[i * 3 + 1] = int(shadow * 255.0)
			out[i * 3 + 2] = int((curv * 0.5 + 0.5) * 255.0)
	return out


## Bilinear height lookup in cell coordinates, clamped at the border.
##
## `outside` is returned for samples off the map rather than the clamped edge
## height: clamping makes the map's own border behave like an infinite ridge or
## an infinite plain depending which way it leans, and both show up as a bright
## or dark frame around the whole biodome. Handing back the centre cell's own
## height makes the border neutral — nothing there occludes, nothing there
## casts.
static func _h_at(heights: PackedFloat32Array, w: int, h: int,
		x: float, z: float, outside: float) -> float:
	if x < 0.0 or z < 0.0 or x > float(w - 1) or z > float(h - 1):
		return outside
	var x0 := int(x)
	var z0 := int(z)
	var x1 := mini(x0 + 1, w - 1)
	var z1 := mini(z0 + 1, h - 1)
	var fx := x - float(x0)
	var fz := z - float(z0)
	var a := heights[z0 * w + x0]
	var b := heights[z0 * w + x1]
	var c := heights[z1 * w + x0]
	var d := heights[z1 * w + x1]
	return (a + (b - a) * fx) + ((c + (d - c) * fx) - (a + (b - a) * fx)) * fz


## Distance in CELLS from (x, z) to the nearest `level` contour of the root-web
## noise, approximated as |f - level| / |grad f|.
##
## That first-order approximation is what turns a value threshold into a band of
## constant width. It is exact for a linear field and good enough anywhere the
## field is not near a saddle; near a saddle the gradient goes to zero and the
## band widens, which is exactly where roots should braid anyway.
##
## The frequency is low on purpose. At the 0.058 it started on, the strands were
## a dense tangle at the scale of a single unit; at this frequency they are long
## sweeping ribbons that cross a whole channel, which is what the reference has.
const WEB_FREQ := 0.030
## THREE seeds, not one, and this is what lets the web BRAID.
##
## A level set of a single scalar field is a family of disjoint simple curves.
## It cannot cross itself — that is a property of level sets, not a tuning
## problem — so one ridge field can never produce the braided, rejoining network
## that is the dominant feature of the reference. Strands from DIFFERENT fields
## have no such constraint: they cross freely, and the union of three sparse
## networks is a braid.
##
## Three rather than two because two crossing families still read as a grid from
## overhead; three breaks the regularity. Each is thinner than the single web it
## replaces, so the total area is comparable while the centreline length roughly
## triples — which is the measured deficit against the reference (44 m of
## centreline per 100 m2 there, against 13.9 m here).
const WEB_SEEDS := [4421, 9173, 2087]

static func _ridge(x: float, z: float, seed_v: int) -> float:
	return 1.0 - absf(_vnoise(x * WEB_FREQ, z * WEB_FREQ, seed_v) * 2.0 - 1.0)

## Distance in CELLS to the nearest strand centreline, over all three webs.
static func _ridge_dist(x: int, z: int, level: float) -> float:
	var best := INF
	for seed_v in WEB_SEEDS:
		var f := _ridge(x, z, seed_v)
		var gx := (_ridge(x + 1, z, seed_v) - _ridge(x - 1, z, seed_v)) * 0.5
		var gz := (_ridge(x, z + 1, seed_v) - _ridge(x, z - 1, seed_v)) * 0.5
		var g := sqrt(gx * gx + gz * gz)
		best = minf(best, absf(f - level) / maxf(g, 0.0005))
	return best
