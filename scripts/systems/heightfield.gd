class_name Heightfield
extends RefCounted
##
## Emits `deformed` rather than touching the event bus directly: an autoload
## does not exist under `godot --headless --script`, and a system that cannot
## run headlessly cannot be tested headlessly. The node that owns a Heightfield
## forwards this to EventBus.terrain_deformed.
## The deformable terrain, as pure data. No rendering, no collision — those
## consume this. Keeping it a plain RefCounted is what makes the numeric
## thresholds testable headlessly, which CLAUDE.md requires and the prototype
## learned the hard way.
##
## Heights are normalized 0-1. `cfg.neutral_height` is flat ground.

signal deformed(world_aabb: AABB)

var cfg: TerrainConfig
var heights: PackedFloat32Array


## Which cells are WATER rather than merely low.
##
## Height alone cannot answer that. A pool in a hollow and the outer rim of a
## plateau occupy the same height band, and "enclosed basin" versus "the edge of
## the world" is a topological distinction a per-fragment shader has no way to
## make — it can see one cell, not the shape around it. So the map author marks
## it here and the shader reads the mark.
##
## Uploaded once, not per frame: digging changes heights constantly and never
## creates a lake.
var water: PackedFloat32Array

## Which GROUND MATERIAL each cell is, as an index.
##
## The reference map is not one surface shaded by height — it is large flat
## areas of distinct stuff with hard organic borders between them: moss flats,
## bare rock, pale sediment at the waterline, dark loam, and the root mat that
## rings every plateau. A height ramp cannot express that, because two places
## at the same altitude are often different materials.
##
## Like `water`, it is authored once and uploaded once. Digging changes the
## shape of the ground, not what it is made of.
var material_id: PackedByteArray

## Cells nothing may walk into, whatever height they are. INVISIBLE WALLS.
##
## The other way to say "you cannot go here" is to dig the ground away, which
## this map already does at the ravine edges and which the editor's BLOCK tool
## still does. That is the honest answer when the obstacle IS the terrain. It is
## the wrong answer for a thicket of alien plants or a cluster of structures:
## those are things standing ON ground that is perfectly fine, and carving a
## chasm under them would say the wrong thing about what is stopping you — as
## well as dropping the props into the hole.
##
## So this is a separate mask. The prop is the visual; this is its collision.
## Nothing renders it and nothing needs to: if the player cannot see why they
## are being stopped, the wall is in the wrong place.
##
## Authored once from `wall` ops and never touched again. Digging changes the
## shape of the ground, not what is standing on it — and a player who trenches
## their way under a wall of alien growth has not earned anything, they have
## found a bug.
var blocked: PackedByteArray


func _init(config: TerrainConfig) -> void:
	cfg = config
	heights = PackedFloat32Array()
	heights.resize(cfg.cells_x * cfg.cells_z)
	water = PackedFloat32Array()
	water.resize(cfg.cells_x * cfg.cells_z)
	material_id = PackedByteArray()
	material_id.resize(cfg.cells_x * cfg.cells_z)
	blocked = PackedByteArray()
	blocked.resize(cfg.cells_x * cfg.cells_z)
	heights.fill(cfg.neutral_height)


func index(cx: int, cz: int) -> int:
	return cz * cfg.cells_x + cx


func height_at_cell(cx: int, cz: int) -> float:
	return heights[index(cx, cz)]


func height_at(world: Vector2) -> float:
	var cx := clampi(int(world.x / cfg.cell_size_m), 0, cfg.cells_x - 1)
	var cz := clampi(int(world.y / cfg.cell_size_m), 0, cfg.cells_z - 1)
	return heights[index(cx, cz)]


func is_passable(world: Vector2) -> bool:
	return not is_walled(world) and height_at(world) > cfg.impassable_below


## Inside an invisible wall. Separate from is_passable so the editor and the
## checks can tell the two reasons apart — "there is no ground" and "something
## is standing there" are different notes to give a designer.
func is_walled(world: Vector2) -> bool:
	var cx := clampi(int(world.x / cfg.cell_size_m), 0, cfg.cells_x - 1)
	var cz := clampi(int(world.y / cfg.cell_size_m), 0, cfg.cells_z - 1)
	return blocked[index(cx, cz)] != 0


## Mark every cell inside a closed outline. Points are in CELL coordinates, the
## same space the polygon and plateau ops use.
##
## The bounding box is walked rather than the whole map: a wall around one
## thicket is a few hundred cells out of sixteen thousand, and the first
## version scanned all of them for every wall.
func wall_polygon(points: PackedVector2Array) -> void:
	if points.size() < 3:
		return
	var lo := points[0]
	var hi := points[0]
	for p in points:
		lo = lo.min(p)
		hi = hi.max(p)
	var x0 := clampi(int(floor(lo.x)), 0, cfg.cells_x - 1)
	var x1 := clampi(int(ceil(hi.x)), 0, cfg.cells_x - 1)
	var z0 := clampi(int(floor(lo.y)), 0, cfg.cells_z - 1)
	var z1 := clampi(int(ceil(hi.y)), 0, cfg.cells_z - 1)
	for z in range(z0, z1 + 1):
		for x in range(x0, x1 + 1):
			# The cell CENTRE, not its corner. Testing the corner puts the
			# wall half a metre off in both axes, which is invisible on a map
			# and exactly wide enough to let a swarmer through a gap the
			# designer drew closed.
			if Geometry2D.is_point_in_polygon(Vector2(x + 0.5, z + 0.5),
					points):
				blocked[index(x, z)] = 1


func is_rough(world: Vector2) -> bool:
	var h := height_at(world)
	return h > cfg.impassable_below and h < cfg.rough_below


func speed_multiplier_at(world: Vector2) -> float:
	return cfg.rough_speed_multiplier if is_rough(world) else 1.0


## The entire deformation system. Cosine-squared falloff, clamped.
##
## `floor_at` exists for incidental scarring: weapon impacts floor at
## `cfg.scar_floor` so a long firefight roughens ground without ever severing
## it and trapping the player's own units.
func deform(world: Vector2, radius_m: float, amount: float, floor_at := -1.0) -> AABB:
	var lower := cfg.clamp_min if floor_at < 0.0 else floor_at
	var gx := world.x / cfg.cell_size_m
	var gz := world.y / cfg.cell_size_m
	var gr := radius_m / cfg.cell_size_m
	var x0 := clampi(int(floor(gx - gr)), 0, cfg.cells_x - 1)
	var x1 := clampi(int(ceil(gx + gr)), 0, cfg.cells_x - 1)
	var z0 := clampi(int(floor(gz - gr)), 0, cfg.cells_z - 1)
	var z1 := clampi(int(ceil(gz + gr)), 0, cfg.cells_z - 1)

	for z in range(z0, z1 + 1):
		for x in range(x0, x1 + 1):
			var d := Vector2(x - gx, z - gz).length()
			if d > gr:
				continue
			var f := cos(d / gr * PI * 0.5)
			var i := index(x, z)
			# A cell already below the floor is left alone rather than raised.
			var target: float = heights[i] + amount * f * f
			heights[i] = clampf(target, minf(lower, heights[i]), cfg.clamp_max)

	return _region(x0, z0, x1, z1)


## Attached-excavator smoothing back toward neutral. Rate-based on purpose:
## the prototype applied a fixed lerp per FRAME, so dig depth depended on
## framerate — which breaks the deterministic sim outright.
func flatten(world: Vector2, radius_m: float, delta: float) -> AABB:
	var strength := clampf(cfg.flatten_rate_per_s * delta, 0.0, 1.0)
	var gx := world.x / cfg.cell_size_m
	var gz := world.y / cfg.cell_size_m
	var gr := radius_m / cfg.cell_size_m
	var x0 := clampi(int(floor(gx - gr)), 0, cfg.cells_x - 1)
	var x1 := clampi(int(ceil(gx + gr)), 0, cfg.cells_x - 1)
	var z0 := clampi(int(floor(gz - gr)), 0, cfg.cells_z - 1)
	var z1 := clampi(int(ceil(gz + gr)), 0, cfg.cells_z - 1)

	for z in range(z0, z1 + 1):
		for x in range(x0, x1 + 1):
			var d := Vector2(x - gx, z - gz).length()
			if d > gr:
				continue
			var i := index(x, z)
			heights[i] = lerpf(heights[i], cfg.neutral_height, strength * (1.0 - d / gr))

	return _region(x0, z0, x1, z1)


func _region(x0: int, z0: int, x1: int, z1: int) -> AABB:
	var s := cfg.cell_size_m
	var aabb := AABB(
		Vector3(x0 * s, 0.0, z0 * s),
		Vector3((x1 - x0 + 1) * s, cfg.height_scale_m, (z1 - z0 + 1) * s)
	)
	deformed.emit(aabb)
	return aabb
