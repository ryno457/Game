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
		_:
			push_warning("TerrainBuilder: unknown op '%s'" % op.get("op", ""))


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
static func classify_materials(hf: Heightfield, void_below: float,
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
			# The root mat, ringing every plateau. Last, so it runs over the
			# cliffs the way it does in the reference.
			if near_edge[i] == 1 and hf.water[i] <= 0.05:
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
