extends SceneTree
## The painted-light bake, checked against shapes whose answer is known.
##
##   godot --headless --path . --script tools/shade_check.gd
##
## Worth testing rather than eyeballing, for the reason CLAUDE.md gives about
## deformation depth: a sign error in the curvature Laplacian, or a sun azimuth
## off by 90 degrees, produces an image that still looks like shading. It is
## lit wrongly, consistently, everywhere — and consistency is exactly what makes
## it survive a look. Every check here is a statement that has one right answer.

var _failed := 0


func _initialize() -> void:
	print("SENTINEL — painted light checks\n")
	_shaders_compile()
	_curvature_sign()
	_ao_sees_the_sky()
	_shadow_falls_away_from_the_sun()
	_resolution_independence()
	_speed()
	print("")
	if _failed == 0:
		print("ALL CHECKS PASSED")
	else:
		print("%d CHECK(S) FAILED" % _failed)
	quit(_failed)


func _ok(name: String, cond: bool, detail: String) -> void:
	if not cond:
		_failed += 1
	print("  %s  %s  %s" % ["PASS" if cond else "FAIL", name.rpad(46), detail])


## A field with one Gaussian bump in the middle, on a flat plain.
func _bump(w: int, h: int, cell_m: float, sigma: float, amp: float) -> Heightfield:
	var cfg := TerrainConfig.new()
	cfg.cells_x = w
	cfg.cells_z = h
	cfg.cell_size_m = cell_m
	cfg.height_scale_m = 12.0
	var hf := Heightfield.new(cfg)
	var cx := float(w) * 0.5
	var cz := float(h) * 0.5
	for z in h:
		for x in w:
			var dx := (float(x) - cx) * cell_m
			var dz := (float(z) - cz) * cell_m
			var r2 := dx * dx + dz * dz
			hf.heights[z * w + x] = 0.35 + amp * exp(-r2 / (2.0 * sigma * sigma))
	return hf


func _palette() -> BiomePalette:
	var p := BiomePalette.new()
	p.sun_azimuth_deg = -90.0     # straight from the west, so the answer is on one axis
	p.sun_elevation_deg = 22.0
	p.ao_reach_m = 8.0
	p.shadow_reach_m = 16.0
	p.shadow_softness_m = 2.0
	p.curv_wide_m = 3.0
	p.curv_gain = 5.0
	return p


func _at(b: PackedByteArray, w: int, x: int, z: int, ch: int) -> float:
	return float(b[(z * w + x) * 3 + ch]) / 255.0


# --- the checks ---------------------------------------------------------------

## The one that catches a sign flip. A bump is CONVEX at its apex and CONCAVE
## where its skirt meets the plain, and the bake stores curvature biased so 0.5
## is flat. Apex must read below 0.5, skirt above it.
func _curvature_sign() -> void:
	var w := 64
	var hf := _bump(w, w, 1.0, 6.0, 0.25)
	var b := TerrainBuilder.bake_shade(hf, _palette())
	var apex := _at(b, w, 32, 32, 2)
	# The skirt: far enough out that the Gaussian has turned over. For sigma 6
	# the inflection is at r = sigma, so 2 sigma is safely in the concave part.
	var skirt := _at(b, w, 32 + 12, 32, 2)
	var flat := _at(b, w, 4, 4, 2)
	_ok("a bump's apex reads convex", apex < 0.5 - 0.002,
		"%.3f, against 0.5 for flat" % apex)
	_ok("and its skirt reads concave", skirt > 0.5 + 0.002, "%.3f" % skirt)
	_ok("and open plain reads flat", absf(flat - 0.5) < 0.004, "%.3f" % flat)


## AO is "how much sky can this cell see". Beside a bump it must see less than
## it does out on the open plain, and the bump's own top must see the most.
func _ao_sees_the_sky() -> void:
	var w := 64
	var hf := _bump(w, w, 1.0, 6.0, 0.25)
	var b := TerrainBuilder.bake_shade(hf, _palette())
	var top := _at(b, w, 32, 32, 0)
	var foot := _at(b, w, 32 + 9, 32, 0)
	var plain := _at(b, w, 4, 4, 0)
	_ok("the foot of a bump is occluded", foot < plain - 0.01,
		"foot %.3f against plain %.3f" % [foot, plain])
	_ok("its top is not", top > foot + 0.01,
		"top %.3f" % top)
	_ok("and open plain is unoccluded", plain > 0.97, "%.3f" % plain)


## The check that catches an azimuth off by a quadrant. With the sun due west,
## the shadow lands due EAST of the bump and nowhere else.
func _shadow_falls_away_from_the_sun() -> void:
	var w := 64
	# Tall and narrow, and sampled close in. A shadow only exists where the
	# blocker rises above the sun ray, so the bump has to out-climb tan(22 deg)
	# over the sample distance or the check is asserting something the geometry
	# forbids — which is how the first version of it failed for the wrong reason.
	var hf := _bump(w, w, 1.0, 3.0, 0.8)
	var b := TerrainBuilder.bake_shade(hf, _palette())
	var east := _at(b, w, 32 + 6, 32, 1)
	var west := _at(b, w, 32 - 6, 32, 1)
	var north := _at(b, w, 32, 32 - 6, 1)
	_ok("a west sun casts shadow to the east", east < west - 0.05,
		"east %.3f, west %.3f" % [east, west])
	_ok("and not across the axis", absf(north - west) < 0.25,
		"north %.3f" % north)
	_ok("the lit side is not shadowed", west > 0.9, "%.3f" % west)


## The bug that is invisible by eye and ruins the look at another heightmap
## resolution: the same physical bump, sampled at half the cell size, must give
## roughly the same curvature. If texel_m is missing from the normalisation this
## comes out 4x different and nothing on screen says so.
func _resolution_independence() -> void:
	var coarse := _bump(48, 48, 2.0, 8.0, 0.25)
	var fine := _bump(96, 96, 1.0, 8.0, 0.25)
	var p := _palette()
	var bc := TerrainBuilder.bake_shade(coarse, p)
	var bf := TerrainBuilder.bake_shade(fine, p)
	var ac := _at(bc, 48, 24, 24, 2)
	var af := _at(bf, 96, 48, 48, 2)
	# Both are apex readings of the same real bump. They will not be identical —
	# a discrete Laplacian is resolution-dependent at second order — but a
	# missing cell_size_m shows up as a factor of four, not a few per cent.
	var ratio := (0.5 - ac) / maxf(0.0001, 0.5 - af)
	_ok("curvature is in metres, not in cells", ratio > 0.55 and ratio < 1.8,
		"coarse/fine apex ratio %.2f" % ratio)


## What this costs. Not a pass/fail on the bake itself — it is a number that has
## to be carried into the deformation work, because it is the budget for a
## per-chunk re-bake and it is not small.
func _speed() -> void:
	var w := 150
	var h := 112
	var hf := _bump(w, h, 1.0, 20.0, 0.3)
	var p := _palette()
	var t0 := Time.get_ticks_usec()
	TerrainBuilder.bake_shade(hf, p)
	var full := (Time.get_ticks_usec() - t0) / 1000.0
	var per_cell := full * 1000.0 / float(w * h)
	# A 25 x 28 chunk is what TerrainView.CHUNK uses.
	var chunk := per_cell * 25.0 * 28.0 / 1000.0
	_ok("a whole map bakes in under a second", full < 1000.0,
		"%.0f ms for %d cells (%.1f us/cell)" % [full, w * h, per_cell])
	print("        one 25 x 28 chunk: %.1f ms  <- the number that matters for digging"
		% chunk)


## Every shader in the project actually compiles.
##
## Worth having as a check rather than trusting a clean boot: headless runs on
## the dummy renderer, so booting the game does NOT compile any shader. A syntax
## error or an undeclared identifier survives `--headless --quit-after 240`
## silently and turns up as a pink screen on the phone, which is a day's round
## trip. Assigning the code to a ShaderMaterial forces the compile, and the
## server prints SHADER ERROR on failure — verified by feeding it a bad shader.
func _shaders_compile() -> void:
	for path in DirAccess.get_files_at("res://shaders"):
		if not path.ends_with(".gdshader"):
			continue
		var full := "res://shaders/" + path
		var code := FileAccess.get_file_as_string(full)
		var sh := Shader.new()
		sh.code = code
		var m := ShaderMaterial.new()
		m.shader = sh
		# Godot reports a compile failure by PUSHING an error rather than
		# returning one, and a failed shader still holds its own source — so
		# comparing the code back is a check that cannot fail. The uniform list
		# can: the server only populates it from a successful parse, so a broken
		# shader reports zero uniforms. Verified both ways against a deliberately
		# broken shader before relying on it.
		var n := sh.get_shader_uniform_list().size()
		_ok("%s compiles" % path, n > 0, "%d uniforms, %d lines"
			% [n, code.count("\n")])
