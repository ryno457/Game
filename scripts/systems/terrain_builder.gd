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
		"band":
			_rect(hf, Rect2(op.x0, op.z0, op.x1 - op.x0, op.z1 - op.z0),
				op.level, float(op.get("edge", 4.0)))
		_:
			push_warning("TerrainBuilder: unknown op '%s'" % op.get("op", ""))


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
