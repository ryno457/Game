class_name DeformField
extends RefCounted
## The heightfield, as plain data, plus dirty-chunk bookkeeping.
##
## Heights are normalized 0-1; multiply by `height_scale_m` for world Y.
## Nothing here knows about rendering or physics — it just records which
## chunks changed so the owners can decide what to re-cook.

var cells: Vector2i
var chunk_cells: int
var chunks: Vector2i
var cell_size: float
var height_scale_m: float
var neutral: float

var heights: PackedFloat32Array
var dirty: Dictionary = {}          # Vector2i -> true

# Cheap noise-free worldgen: deterministic value noise, seeded.
var _rng := RandomNumberGenerator.new()


func _init(p_cells: Vector2i, p_chunk_cells: int, p_cell_size: float,
		p_height_scale: float, p_neutral: float, p_seed: int) -> void:
	cells = p_cells
	chunk_cells = p_chunk_cells
	cell_size = p_cell_size
	height_scale_m = p_height_scale
	neutral = p_neutral
	chunks = Vector2i(cells.x / chunk_cells, cells.y / chunk_cells)
	_rng.seed = p_seed

	# One extra sample row/column: chunk edges must share vertices or the
	# collision shapes crack apart at the seams.
	heights = PackedFloat32Array()
	heights.resize((cells.x + 1) * (cells.y + 1))
	generate()


func samples() -> Vector2i:
	return Vector2i(cells.x + 1, cells.y + 1)


func index(sx: int, sz: int) -> int:
	return sz * (cells.x + 1) + sx


func generate() -> void:
	var s := samples()
	for z in s.y:
		for x in s.x:
			var n := _noise(x * 0.055, z * 0.055) * 0.6
			n += _noise(x * 0.14, z * 0.14) * 0.28
			n += _noise(x * 0.31, z * 0.31) * 0.12
			heights[index(x, z)] = clampf(neutral + (n - 0.5) * 0.30, 0.02, 0.98)
	mark_all_dirty()


func _noise(x: float, y: float) -> float:
	var xi := floori(x)
	var yi := floori(y)
	var xf := x - xi
	var yf := y - yi
	var u := xf * xf * (3.0 - 2.0 * xf)
	var v := yf * yf * (3.0 - 2.0 * yf)
	return lerpf(
		lerpf(_hash(xi, yi), _hash(xi + 1, yi), u),
		lerpf(_hash(xi, yi + 1), _hash(xi + 1, yi + 1), u),
		v)


func _hash(a: int, b: int) -> float:
	var n: float = sin(a * 127.1 + b * 311.7) * 43758.5453
	return n - floor(n)


## Load an authored heightfield — the Biodome 01 test map — over the generated
## noise. Returns false and leaves the noise in place if the file is missing or
## the wrong shape, so a bad bake degrades the spike instead of breaking it.
func load_heights(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("heightfield not found: %s" % path)
		return false
	var raw := f.get_buffer(f.get_length())
	f.close()
	if raw.size() != heights.size() * 4:
		push_warning("heightfield %s is %d bytes, expected %d" %
			[path, raw.size(), heights.size() * 4])
		return false
	heights = raw.to_float32_array()
	mark_all_dirty()
	return true


func mark_all_dirty() -> void:
	for cz in chunks.y:
		for cx in chunks.x:
			dirty[Vector2i(cx, cz)] = true


## Cosine-squared falloff, same curve as the JS prototype. `floor_at` below 0
## means "use the hard clamp"; pass a higher floor for incidental scarring so
## weapons can roughen ground without ever severing it.
## Returns the number of samples touched, for cost attribution.
func deform(world_xz: Vector2, radius_m: float, amount: float, floor_at := -1.0) -> int:
	var lower := 0.02 if floor_at < 0.0 else floor_at
	var gx := world_xz.x / cell_size
	var gz := world_xz.y / cell_size
	var gr := radius_m / cell_size
	var s := samples()
	var x0 := clampi(floori(gx - gr), 0, s.x - 1)
	var x1 := clampi(ceili(gx + gr), 0, s.x - 1)
	var z0 := clampi(floori(gz - gr), 0, s.y - 1)
	var z1 := clampi(ceili(gz + gr), 0, s.y - 1)
	var touched := 0

	for z in range(z0, z1 + 1):
		for x in range(x0, x1 + 1):
			var d := Vector2(x - gx, z - gz).length()
			if d > gr:
				continue
			var f := cos(d / gr * PI * 0.5)
			var i := index(x, z)
			var h: float = heights[i] + amount * f * f
			heights[i] = clampf(h, minf(lower, heights[i]), 0.98)
			touched += 1

	_dirty_region(x0, z0, x1, z1)
	return touched


func _dirty_region(x0: int, z0: int, x1: int, z1: int) -> void:
	# A sample on a chunk seam belongs to both chunks; widen by one so the
	# neighbour re-cooks too, or collision cracks along the edge.
	var cx0 := clampi((x0 - 1) / chunk_cells, 0, chunks.x - 1)
	var cx1 := clampi((x1 + 1) / chunk_cells, 0, chunks.x - 1)
	var cz0 := clampi((z0 - 1) / chunk_cells, 0, chunks.y - 1)
	var cz1 := clampi((z1 + 1) / chunk_cells, 0, chunks.y - 1)
	for cz in range(cz0, cz1 + 1):
		for cx in range(cx0, cx1 + 1):
			dirty[Vector2i(cx, cz)] = true


func height_at(world_xz: Vector2) -> float:
	var s := samples()
	var sx := clampi(int(world_xz.x / cell_size), 0, s.x - 1)
	var sz := clampi(int(world_xz.y / cell_size), 0, s.y - 1)
	return heights[index(sx, sz)]


func world_height_at(world_xz: Vector2) -> float:
	return height_at(world_xz) * height_scale_m


func is_passable(world_xz: Vector2, impassable_below: float) -> bool:
	return height_at(world_xz) > impassable_below


func extent_m() -> Vector2:
	return Vector2(cells.x * cell_size, cells.y * cell_size)


## Heights for one chunk's collision shape, in WORLD Y units. HeightMapShape3D
## wants (chunk_cells + 1)^2 samples at 1-unit spacing.
func chunk_collision_data(cx: int, cz: int) -> PackedFloat32Array:
	var n := chunk_cells + 1
	var out := PackedFloat32Array()
	out.resize(n * n)
	var ox := cx * chunk_cells
	var oz := cz * chunk_cells
	for z in n:
		var row := z * n
		var src := index(ox, oz + z)
		for x in n:
			out[row + x] = heights[src + x] * height_scale_m
	return out
