class_name Dressing
extends RefCounted
## Places a biodome's scenery from a seed.
##
## Deterministic and free of the scene, like Heightfield and MassPool, so the
## question "does this map put an arch on top of the player" has a headless
## answer. Same seed and same terrain give the same map every time, on every
## device, which is also what makes the dressing free to save.
##
## Rejection sampling rather than anything clever: pick a point, test it
## against the rule, keep it or throw it away. At a few hundred props on a map
## of sixteen thousand cells that is a handful of milliseconds once at load.

const TRIES_PER_PROP := 24


## model name -> Array[Transform3D], ready to hand to a MultiMesh.
static func place(field: Heightfield, plan: BiomeDressing, landing: Vector2) -> Dictionary:
	var out := {}
	if field == null or plan == null:
		return out
	var cfg := field.cfg
	var rng := RandomNumberGenerator.new()
	rng.seed = plan.seed
	var taken: Array[Vector2] = []

	for entry in plan.entries:
		var spots: Array[Transform3D] = []
		var centres := _thickets(field, plan, entry, rng, landing)
		for i in entry.count:
			for attempt in TRIES_PER_PROP:
				var p := _sample(cfg, entry, centres, rng)
				if not _fits(field, plan, entry, p, taken, landing):
					continue
				taken.append(p)
				spots.append(_transform(field, entry, p, rng))
				break
		out[entry.model] = spots
	return out


## Thicket centres for a clustered entry, or an empty list for a uniform one.
static func _thickets(field: Heightfield, plan: BiomeDressing, entry: PropScatter,
		rng: RandomNumberGenerator, landing: Vector2) -> Array[Vector2]:
	var out: Array[Vector2] = []
	if entry.clusters <= 0:
		return out
	var cfg := field.cfg
	var none: Array[Vector2] = []
	for i in entry.clusters:
		for attempt in TRIES_PER_PROP:
			var p := Vector2(
				rng.randf_range(2.0, cfg.cells_x - 2.0),
				rng.randf_range(2.0, cfg.cells_z - 2.0))
			# A centre only has to be legal ground, not clear of other props —
			# thickets are allowed to overlap into one bigger stand.
			if _fits(field, plan, entry, p, none, landing):
				out.append(p)
				break
	return out


static func _sample(cfg: TerrainConfig, entry: PropScatter, centres: Array[Vector2],
		rng: RandomNumberGenerator) -> Vector2:
	if centres.is_empty():
		return Vector2(rng.randf_range(2.0, cfg.cells_x - 2.0),
			rng.randf_range(2.0, cfg.cells_z - 2.0))
	# sqrt of a uniform draw gives an even area density inside the disc; a raw
	# uniform radius piles everything at the centre.
	var c: Vector2 = centres[rng.randi() % centres.size()]
	var a := rng.randf() * TAU
	var r := sqrt(rng.randf()) * entry.cluster_radius_m
	return Vector2(
		clampf(c.x + cos(a) * r, 2.0, cfg.cells_x - 2.0),
		clampf(c.y + sin(a) * r, 2.0, cfg.cells_z - 2.0))


static func _fits(field: Heightfield, plan: BiomeDressing, entry: PropScatter,
		p: Vector2, taken: Array[Vector2], landing: Vector2) -> bool:
	var h := field.height_at(p)
	if h < entry.height_min or h > entry.height_max:
		return false
	if slope_at(field, p) > entry.max_slope:
		return false
	if p.distance_to(landing) < plan.landing_clear_m:
		return false
	for q in taken:
		if p.distance_squared_to(q) < entry.clearance_m * entry.clearance_m:
			return false
	return true


## 1 - normal.y at a point, from the same central difference the vertex shader
## uses, so "too steep to grow on" means the same thing in both places.
static func slope_at(field: Heightfield, p: Vector2) -> float:
	var e := field.cfg.cell_size_m
	var sy := field.cfg.height_scale_m
	var dx := (field.height_at(p - Vector2(e, 0.0)) - field.height_at(p + Vector2(e, 0.0))) * sy
	var dz := (field.height_at(p - Vector2(0.0, e)) - field.height_at(p + Vector2(0.0, e))) * sy
	var n := Vector3(dx, 2.0 * e, dz).normalized()
	return 1.0 - clampf(n.y, 0.0, 1.0)


static func _transform(field: Heightfield, entry: PropScatter, p: Vector2,
		rng: RandomNumberGenerator) -> Transform3D:
	var s := rng.randf_range(entry.scale_min, entry.scale_max)
	var b := Basis.IDENTITY.rotated(Vector3.UP, rng.randf() * TAU)
	if entry.follow_slope > 0.0:
		# Lean with the ground, but only partway: a plant grows toward the
		# light, so a tendril on a slope should not lie down flat on it.
		var e := field.cfg.cell_size_m
		var sy := field.cfg.height_scale_m
		var dx := (field.height_at(p - Vector2(e, 0.0))
			- field.height_at(p + Vector2(e, 0.0))) * sy
		var dz := (field.height_at(p - Vector2(0.0, e))
			- field.height_at(p + Vector2(0.0, e))) * sy
		var n := Vector3(dx, 2.0 * e, dz).normalized()
		var axis := Vector3.UP.cross(n)
		if axis.length() > 0.0001:
			b = Basis(axis.normalized(), Vector3.UP.angle_to(n) * entry.follow_slope) * b
	b = b.scaled(Vector3.ONE * s)
	var y := field.height_at(p) * field.cfg.height_scale_m - entry.sink_m * s
	return Transform3D(b, Vector3(p.x, y, p.y))
