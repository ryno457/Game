extends SceneTree
## Rules of reforging machines in the field, tested without a scene.
##
##   godot --headless --path . --script tools/merge_check.gd
##
## The load-bearing claim is the player's: "if you want a bigger unit then two
## units need to come together to form the bigger unit". That is an arithmetic
## statement about mass, so it is checked as one.

const RULES := "res://data/gameplay/merge.tres"
const MACHINES := "res://data/gameplay/machines.tres"
const MASS := "res://data/gameplay/mass.tres"
const OPTIONS_DIR := "res://data/gameplay/build_options/"

var _failed := 0
var _forge: MergeRules
var _mass: MassConfig
var _options: Array = []
var _specs := {}


func _initialize() -> void:
	print("SENTINEL — field reforging checks\n")
	_forge = load(RULES)
	_mass = load(MASS)
	var machine_rules: MachineRules = load(MACHINES)
	for f in DirAccess.get_files_at(OPTIONS_DIR):
		if f.ends_with(".tres"):
			var o: BuildOption = load(OPTIONS_DIR + f)
			_options.append(o)
			_specs[o.id] = o.spec(machine_rules)
	_options.sort_custom(func(a, b): return _specs[a.id].mass < _specs[b.id].mass)

	_bigger_needs_two()
	_conservation()
	_cost()
	_limits()
	print("")
	if _failed == 0:
		print("ALL CHECKS PASSED")
	else:
		print("%d CHECK(S) FAILED" % _failed)
	quit(_failed)


func _ok(name: String, cond: bool, detail: String) -> void:
	if not cond:
		_failed += 1
	print("  %s  %s  %s" % ["PASS" if cond else "FAIL", name.rpad(42), detail])


func _spec(id: String) -> MachineSpec:
	return _specs[StringName(id)]


func _names(list: Array) -> String:
	return ", ".join(list.map(func(o): return o.display_name))


# --- the rule ---------------------------------------------------------------
func _bigger_needs_two() -> void:
	print("one machine, or two")
	var skirm := _spec("SKIRMISHER")
	var lancer := _spec("LANCER")

	var alone := MergePlanner.candidates(skirm.mass, _options, _specs, skirm.id)
	_ok("one machine can still change shape", alone.size() > 0,
		"%d mass offers %d: %s" % [skirm.mass, alone.size(), _names(alone)])
	_ok("but only into something no bigger",
		alone.all(func(o): return _specs[o.id].mass <= skirm.mass + 0.001),
		"nothing offered above %.0f mass" % skirm.mass)
	_ok("a Lancer is out of reach for one Skirmisher",
		not alone.any(func(o): return o.id == &"LANCER"),
		"%.0f mass needed, %.0f standing" % [lancer.mass, skirm.mass])

	# The player's rule, stated exactly: bring a second machine and the bigger
	# shape becomes available.
	var pair := MergePlanner.pool_mass([skirm, skirm])
	var together := MergePlanner.candidates(pair, _options, _specs)
	_ok("two Skirmishers reach the Lancer",
		together.any(func(o): return o.id == &"LANCER"),
		"%.0f + %.0f = %.0f mass" % [skirm.mass, skirm.mass, pair])
	_ok("two of them reach strictly more than one",
		together.size() > alone.size(), "%d offers -> %d" % [alone.size(), together.size()])
	_ok("the heaviest offer is what the pool affords",
		_specs[MergePlanner.best(pair, _options, _specs).id].mass <= pair,
		"best of %.0f mass: %s"
			% [pair, MergePlanner.best(pair, _options, _specs).display_name])

	# And three reach further again — the ladder has to keep going or merging
	# stops being a way to grow an army into heavier machines.
	var trio := MergePlanner.pool_mass([skirm, skirm, skirm])
	var big := MergePlanner.best(trio, _options, _specs)
	_ok("three reach a machine two cannot",
		_specs[big.id].mass > _specs[MergePlanner.best(pair, _options, _specs).id].mass,
		"%.0f mass buys a %s" % [trio, big.display_name])


# --- nothing is destroyed ----------------------------------------------------
func _conservation() -> void:
	print("\nmass is still conserved")
	var skirm := _spec("SKIRMISHER")
	var pool := MergePlanner.pool_mass([skirm, skirm])
	var target := _spec("LANCER")
	var spare := MergePlanner.leftover(pool, target.mass)
	_ok("pool equals the new machine plus the offcut",
		is_equal_approx(target.mass + spare, pool),
		"%.0f = %.0f + %.1f" % [pool, target.mass, spare])
	_ok("an offcut this size is worth a drone trip",
		not MergePlanner.is_crumb(spare, _forge),
		"%.1f spare, floor %.1f" % [spare, _forge.leftover_floor])

	# A crumb goes home instead of littering the field — still not destroyed.
	var crumb := MergePlanner.leftover(target.mass + 0.4, target.mass)
	_ok("a crumb goes back to the module instead", MergePlanner.is_crumb(crumb, _forge),
		"%.1f spare is under the %.1f floor" % [crumb, _forge.leftover_floor])
	_ok("an exact merge leaves nothing at all",
		is_equal_approx(MergePlanner.leftover(target.mass, target.mass), 0.0), "0.0 spare")

	# Every offer, not just the convenient one.
	var worst := 0.0
	for o in MergePlanner.candidates(pool, _options, _specs):
		var s: float = MergePlanner.leftover(pool, _specs[o.id].mass)
		worst = maxf(worst, absf(pool - (_specs[o.id].mass + s)))
	_ok("conservation holds for every offer", is_equal_approx(worst, 0.0),
		"worst discrepancy %.6f mass" % worst)


# --- what it costs -----------------------------------------------------------
func _cost() -> void:
	print("\nthe price is time")
	var lancer := _spec("LANCER")
	var scratch := _mass.build_time_for(lancer.mass)
	var reforge := MergePlanner.work_time(lancer.mass, _mass, _forge)
	_ok("reforging is faster than building from scratch", reforge < scratch,
		"%.1fs vs %.1fs — the parts already exist" % [reforge, scratch])
	_ok("but it is never free", reforge >= _forge.min_work_s,
		"floor %.1fs" % _forge.min_work_s)
	_ok("a heavier target takes longer",
		MergePlanner.work_time(_spec("SIEGE_BATTERY").mass, _mass, _forge) > reforge,
		"%.1fs for a Siege Battery"
			% MergePlanner.work_time(_spec("SIEGE_BATTERY").mass, _mass, _forge))

	# The machines have to physically meet, which is the other half of the cost.
	_ok("the group has to come together", _forge.gather_radius_m > 0.0,
		"within %.1f m of each other" % _forge.gather_radius_m)
	_ok("and the attempt can fail", _forge.gather_timeout_s > 0.0,
		"abandoned after %.0fs" % _forge.gather_timeout_s)


# --- limits ------------------------------------------------------------------
func _limits() -> void:
	print("\nlimits")
	_ok("a group of one is legal", MergePlanner.group_is_legal(1, _forge), "reshape in place")
	_ok("a group of none is not", not MergePlanner.group_is_legal(0, _forge), "nothing selected")
	_ok("the group is capped",
		not MergePlanner.group_is_legal(_forge.max_group + 1, _forge),
		"%d machines at once" % _forge.max_group)

	# Enough mass for anything must still not offer a machine that does not
	# exist, and must never offer the identical machine back to a lone one.
	var everything := MergePlanner.candidates(9999.0, _options, _specs)
	_ok("an enormous pool offers the whole catalogue",
		everything.size() == _options.size(), "%d machines" % everything.size())
	var lone := MergePlanner.candidates(9999.0, _options, _specs, &"LANCER")
	_ok("a lone machine is never offered itself",
		not lone.any(func(o): return o.id == &"LANCER"),
		"Lancer excluded from its own list")
	_ok("offers are heaviest first",
		_specs[everything[0].id].mass >= _specs[everything[-1].id].mass,
		"%.0f down to %.0f mass"
			% [_specs[everything[0].id].mass, _specs[everything[-1].id].mass])
