class_name TerrainBuilder
extends RefCounted
## Turns a TerrainMap into a Heightfield, deterministically.
##
## Same input always gives the same field — no RandomNumberGenerator state
## leaks between ops, and the noise is a pure function of cell coordinates.
## That is what lets a test map be a stable fixture rather than a moving
## target, and what makes "seed + diff" a viable save format.

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
		range_m: float = 20.0) -> PackedByteArray:
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

	var d_edge := DistanceField.compute(edge, cfg.cells_x, cfg.cells_z, range_m)
	var d_strand := DistanceField.compute(strand, cfg.cells_x, cfg.cells_z, range_m)
	var d_shore := DistanceField.compute(shore, cfg.cells_x, cfg.cells_z, range_m)

	var out := PackedByteArray()
	out.resize(n * 3)
	for i in n:
		out[i * 3] = int(clampf(d_edge[i] / range_m, 0.0, 1.0) * 255.0)
		out[i * 3 + 1] = int(clampf(d_strand[i] / range_m, 0.0, 1.0) * 255.0)
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
		rim_m: float = 2.5, shore_m: float = 3.0) -> Dictionary:
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
			# A ridged fold of value noise gives strands a few metres wide that
			# branch and rejoin, which is what the reference actually shows.
			var in_channel := false
			if channel_below > 0.0 and height < channel_below:
				var n := _vnoise(x * 0.058, z * 0.058, 4421)
				var strand := 1.0 - absf(n * 2.0 - 1.0)
				# Higher is narrower. 0.60 left the mat on half the map; the
				# strands have to be genuinely thin for open ground to win.
				in_channel = strand > web_threshold
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
