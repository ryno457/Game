extends GutTest
## Numeric thresholds on the terrain. "Verify deformation against the
## passability threshold with a headless test, never by eye" — CLAUDE.md.

var cfg: TerrainConfig
var field: Heightfield

const PROBE := Vector2(40.0, 40.0)


func before_each() -> void:
	cfg = load("res://data/terrain/biodome_01.tres").duplicate()
	field = Heightfield.new(cfg)


func test_neutral_ground_is_passable() -> void:
	assert_true(field.is_passable(PROBE))
	assert_eq(field.speed_multiplier_at(PROBE), 1.0)


func test_excavator_actually_breaches_the_impassable_threshold() -> void:
	# THE regression test for this project. A dig rate that looks like it works
	# but never crosses `impassable_below` gives trenches that read as
	# cosmetic dents, which is exactly what the first prototype pass shipped.
	var dug := 0.0
	var step := 1.0 / 60.0
	while dug < 3.0:
		field.deform(PROBE, cfg.excavator_radius_m, cfg.excavator_rate_per_s * step)
		dug += step
		if not field.is_passable(PROBE):
			break
	assert_false(field.is_passable(PROBE),
		"excavator must cut below impassable_below within 3s of sustained digging")
	assert_lt(dug, 1.0, "and it must feel deliberate, not glacial")


func test_ground_passes_through_rough_before_becoming_impassable() -> void:
	# Trenches must read as a gradient the player can see coming.
	field.deform(PROBE, cfg.excavator_radius_m, -0.14)
	assert_true(field.is_rough(PROBE), "should be rough at this depth")
	assert_true(field.is_passable(PROBE), "but not yet severed")
	assert_eq(field.speed_multiplier_at(PROBE), cfg.rough_speed_multiplier)


func test_weapon_scarring_can_never_trap_friendly_units() -> void:
	# A long firefight in one place must not dig its own moat.
	for i in 2000:
		field.deform(PROBE, cfg.weapon_scar_radius_m, cfg.weapon_scar_delta, cfg.scar_floor)
	assert_true(field.is_passable(PROBE),
		"incidental scarring must floor at scar_floor, not clamp_min")
	assert_almost_eq(field.height_at(PROBE), cfg.scar_floor, 0.001)


func test_flatten_is_frame_rate_independent() -> void:
	# The prototype lerped a fixed 0.10 per FRAME, so flattening ran twice as
	# fast at 120fps. That breaks the deterministic sim requirement outright.
	var slow := Heightfield.new(cfg)
	var fast := Heightfield.new(cfg)
	slow.deform(PROBE, 3.0, -0.20)
	fast.deform(PROBE, 3.0, -0.20)

	for i in 30:
		slow.flatten(PROBE, cfg.flatten_radius_m, 1.0 / 30.0)
	for i in 120:
		fast.flatten(PROBE, cfg.flatten_radius_m, 1.0 / 120.0)

	assert_almost_eq(slow.height_at(PROBE), fast.height_at(PROBE), 0.02,
		"one second of flattening must be one second of flattening")


func test_deform_respects_the_hard_clamp() -> void:
	field.deform(PROBE, 2.0, -50.0)
	assert_gte(field.height_at(PROBE), cfg.clamp_min)
	field.deform(PROBE, 2.0, 50.0)
	assert_lte(field.height_at(PROBE), cfg.clamp_max)
