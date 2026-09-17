class_name WaterProbes
extends RefCounted
## Reflection probes over the pools, found from the map rather than authored.
##
## A ReflectionProbe is one of exactly two global-illumination features the
## Forward MOBILE renderer will actually run (the other is LightmapGI, which
## this map cannot use — see the class comment below). It is worth having here
## for one reason: terrain_lit.gdshader drops the ground to ROUGHNESS 0.12 and
## SPECULAR 0.6 under the waterline, so the pools are the only GLOSSY surface
## on the map, and a glossy surface with nothing to reflect is just a darker
## matte one.
##
## FOUND, NOT PLACED. The probes come from the heightfield's own water mask by
## flood fill, so changing the map moves them and nobody has to remember. The
## alternative — a list of positions in the biodome author next to the ops that
## make the pools — is the same data written twice, and the copy that is not
## the source of truth is the one that goes stale.
##
## WHY NOT LightmapGI. It is the better tool for a map whose shape is now
## fixed, and it cannot be used here: the terrain mesh is generated at load by
## TerrainView, so there is nothing for the editor to bake at bake time; it
## carries no UV2, which a lightmap needs; and LightmapGI.bake() is not exposed
## to scripting in this build, so a headless pipeline cannot drive it either.
## All three would have to change together.

const MIN_CELLS := 12       # a puddle smaller than this reflects nothing useful


## One probe per pool. `water` is Heightfield.water, one byte per cell.
static func build(field: Heightfield, p: BiomePalette) -> Array[ReflectionProbe]:
	var out: Array[ReflectionProbe] = []
	if not p.reflection_enabled:
		return out
	var cfg := field.cfg
	var w := cfg.cells_x
	var h := cfg.cells_z
	var seen := PackedByteArray()
	seen.resize(w * h)

	for start in w * h:
		if seen[start] == 1 or field.water[start] <= 0.05:
			continue
		# Flood fill this pool, tracking its bounds as we go.
		var queue: PackedInt32Array = PackedInt32Array([start])
		seen[start] = 1
		var n := 0
		var lo := Vector2i(w, h)
		var hi := Vector2i(-1, -1)
		var sum_y := 0.0
		while queue.size() > 0:
			var i: int = queue[queue.size() - 1]
			queue.remove_at(queue.size() - 1)
			var cx := i % w
			var cz := i / w
			n += 1
			lo = Vector2i(mini(lo.x, cx), mini(lo.y, cz))
			hi = Vector2i(maxi(hi.x, cx), maxi(hi.y, cz))
			sum_y += field.heights[i]
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0),
					Vector2i(0, 1), Vector2i(0, -1)]:
				var nx: int = cx + d.x
				var nz: int = cz + d.y
				if nx < 0 or nz < 0 or nx >= w or nz >= h:
					continue
				var j: int = nz * w + nx
				if seen[j] == 1 or field.water[j] <= 0.05:
					continue
				seen[j] = 1
				queue.append(j)
		if n < MIN_CELLS:
			continue
		out.append(_probe(cfg, lo, hi, sum_y / n, p))
	return out


static func _probe(cfg: TerrainConfig, lo: Vector2i, hi: Vector2i,
		mean_h: float, p: BiomePalette) -> ReflectionProbe:
	var rp := ReflectionProbe.new()
	var m := cfg.cell_size_m
	var surface := mean_h * cfg.height_scale_m
	rp.position = Vector3((lo.x + hi.x + 1) * 0.5 * m,
		surface + p.reflection_height_m * 0.5,
		(lo.y + hi.y + 1) * 0.5 * m)
	# The box has to reach ABOVE the water far enough to contain what is worth
	# reflecting — the rim, the roots on it, anything standing there — and only
	# just below, because there is nothing under a pool but more pool.
	rp.size = Vector3((hi.x - lo.x + 1) * m + p.reflection_margin_m * 2.0,
		p.reflection_height_m,
		(hi.y - lo.y + 1) * m + p.reflection_margin_m * 2.0)
	rp.intensity = p.reflection_intensity
	rp.max_distance = p.reflection_max_distance_m
	# ONCE, not ALWAYS. Nothing that moves is worth reflecting in a pool at this
	# camera, and ALWAYS re-renders six faces per probe per frame — on a phone
	# that is the whole frame budget for a detail nobody would name.
	rp.update_mode = ReflectionProbe.UPDATE_ONCE
	# The probe supplies reflections only. Left on, its ambient would fight the
	# Environment's sky ambient, which is what the whole rig is tuned against.
	rp.ambient_mode = ReflectionProbe.AMBIENT_DISABLED
	rp.enable_shadows = false
	rp.interior = false
	rp.name = "PoolProbe_%d_%d" % [lo.x, lo.y]
	return rp
