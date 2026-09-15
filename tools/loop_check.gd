extends SceneTree
## Rules of the v2 loop, tested without a scene.
##
##   godot --headless --path . --script tools/loop_check.gd

var _failed := 0


func _initialize() -> void:
	print("SENTINEL — mass loop checks\n")
	_mass()
	_waves()
	_fog()
	print("")
	if _failed == 0:
		print("ALL CHECKS PASSED")
	else:
		print("%d CHECK(S) FAILED" % _failed)
	quit(_failed)


func _ok(name: String, cond: bool, detail: String) -> void:
	if not cond:
		_failed += 1
	print("  %s  %s  %s" % ["PASS" if cond else "FAIL", name.rpad(38), detail])


func _cfg() -> MassConfig:
	return load("res://data/gameplay/mass.tres").duplicate()


# --- mass -------------------------------------------------------------------
func _mass() -> void:
	print("mass economy")
	var cfg := _cfg()
	var pool := MassPool.new(cfg)
	_ok("starts at configured mass", is_equal_approx(pool.mass, cfg.starting_mass),
		"%.0f" % pool.mass)

	# The reserve is a floor, not a suggestion.
	var huge := cfg.starting_mass - cfg.reserve_mass + 0.01
	_ok("cannot spend into the reserve", not pool.spend(huge),
		"refused %.2f with reserve %.0f" % [huge, cfg.reserve_mass])
	_ok("mass unchanged after refusal", is_equal_approx(pool.mass, cfg.starting_mass),
		"%.0f" % pool.mass)

	var ok := pool.spend(10.0)
	_ok("affordable spend succeeds", ok and is_equal_approx(pool.mass, cfg.starting_mass - 10.0),
		"%.0f left" % pool.mass)

	# MASS IS CONSERVED. It is the module's body relocated into a unit, never
	# consumed, so a wreck returns every gram. What stops free repurposing is
	# time: the drone has to fly out and haul the wreck home, and the rebuild
	# takes `build_time_s` during which the unit does not exist.
	var before_mass := pool.mass
	var back := pool.recover(10.0)
	_ok("wreck recovery is lossless", is_equal_approx(back, 10.0),
		"%.2f of 10.0 returned" % back)
	_ok("build then recover is a round trip", is_equal_approx(pool.mass, cfg.starting_mass),
		"%.0f -> %.0f -> %.0f" % [cfg.starting_mass, before_mass, pool.mass])
	_ok("scrapping is lossless too", is_equal_approx(cfg.scrap_loss, 0.0)
		and is_equal_approx(cfg.recovery_loss, 0.0),
		"scrap %.0f%%, wreck %.0f%%" % [cfg.scrap_loss * 100.0, cfg.recovery_loss * 100.0])

	# Churn must cost nothing in mass and something in time, or conservation is
	# a lie in one direction and repurposing is free in the other.
	var churn := MassPool.new(_cfg())
	var start := churn.mass
	for i in 5:
		churn.spend(10.0)
		churn.scrap(10.0)
	_ok("churning conserves mass", is_equal_approx(churn.mass, start),
		"%.1f -> %.1f over 5 build/scrap cycles" % [start, churn.mass])
	_ok("churning costs time instead", cfg.build_time_s > 0.0,
		"%.1fs per rebuild, %.1fs for those 5" % [cfg.build_time_s, cfg.build_time_s * 5.0])

	# Mass committed to standing units is not gone, it is somewhere else. The
	# module body plus the field must hold constant across a build.
	var book := MassPool.new(_cfg())
	var total_before := MassPool.total_in_system(book.mass, 0.0)
	book.spend(10.0)
	_ok("nothing leaves the system when building",
		is_equal_approx(MassPool.total_in_system(book.mass, 10.0), total_before),
		"%.1f total before and after" % total_before)

	var cap := MassPool.new(_cfg())
	cap.gain(9999.0)
	_ok("mass is capped", is_equal_approx(cap.mass, cfg.max_mass), "%.0f" % cap.mass)

	# The module's size is the only cost readout the player needs.
	var small := MassPool.new(_cfg())
	var big := MassPool.new(_cfg())
	big.gain(cfg.max_mass)
	_ok("bigger mass reads as bigger module", big.display_scale() > small.display_scale(),
		"scale %.2f -> %.2f" % [small.display_scale(), big.display_scale()])
	_ok("module scale stays within configured bounds",
		small.display_scale() >= cfg.scale_at_min and big.display_scale() <= cfg.scale_at_max,
		"[%.2f, %.2f]" % [cfg.scale_at_min, cfg.scale_at_max])


# --- waves ------------------------------------------------------------------
func _waves() -> void:
	print("\nwave trigger")
	var table: WaveTable = load("res://data/waves/biodome_01.tres")
	var wd := WaveDirector.new(table)

	_ok("quiet until the player acts", not wd.is_active(), "no wave on startup")

	var spawns: Array[int] = [0]
	wd.spawn_due.connect(func(count, _i): spawns[0] += count)
	for i in 600:
		wd.tick(1.0 / 60.0)
	_ok("idle time spawns nothing", spawns[0] == 0,
		"%d hostiles after 10s of not digging" % spawns[0])

	wd.begin(&"debris_large_01", 1.0)
	_ok("freeing debris starts the attack", wd.is_active(), "source %s" % wd.active_source)

	for i in 60 * 60:
		wd.tick(1.0 / 60.0)
	_ok("attack produces hostiles while digging", spawns[0] > 0,
		"%d hostiles over 60s of digging" % spawns[0])

	# Pressure must ramp, or a long dig is no harder than a short one.
	var early := WaveDirector.new(table)
	early.begin(&"x", 1.0)
	var early_size := early.group_size()
	for i in 120 * 60:
		early.tick(1.0 / 60.0)
	_ok("longer digs get harder", early.group_size() > early_size,
		"group %d -> %d over two minutes" % [early_size, early.group_size()])

	# And the player must be able to end it.
	var before: int = spawns[0]
	wd.end()
	for i in 600:
		wd.tick(1.0 / 60.0)
	_ok("freeing the piece ends the attack", not wd.is_active() and spawns[0] == before,
		"no further spawns after the piece came free")

	var big := WaveDirector.new(table)
	big.begin(&"y", 2.5)
	var small := WaveDirector.new(table)
	small.begin(&"z", 1.0)
	_ok("bigger prize, harder fight", big.group_size() > small.group_size(),
		"intensity 2.5 -> %d vs 1.0 -> %d" % [big.group_size(), small.group_size()])


# --- fog --------------------------------------------------------------------
func _fog() -> void:
	print("\nfog of war")
	var fog := FogOfWar.new(Vector2i(150, 112), 1.0)
	var here := Vector2(40.0, 40.0)
	var far := Vector2(120.0, 90.0)

	_ok("everything starts hidden", fog.level_at(here) == FogOfWar.HIDDEN
			and is_zero_approx(fog.explored_fraction()), "0% explored")

	fog.begin_frame()
	fog.reveal(here, 10.0)
	_ok("reveal makes ground visible", fog.is_visible(here), "level %.2f" % fog.level_at(here))
	_ok("distant ground stays hidden", fog.level_at(far) == FogOfWar.HIDDEN,
		"level %.2f" % fog.level_at(far))

	# Move the source away: the ground is remembered, but no longer watched.
	fog.begin_frame()
	fog.reveal(far, 10.0)
	_ok("explored ground is remembered", fog.level_at(here) == FogOfWar.EXPLORED,
		"level %.2f — dim, not black" % fog.level_at(here))
	_ok("but is no longer watched", not fog.is_visible(here),
		"live contacts there would be hidden")

	var frac := fog.explored_fraction()
	_ok("exploration accumulates", frac > 0.0 and frac < 0.25,
		"%.1f%% of the map seen so far" % (frac * 100.0))
