extends SceneTree
## Rules of machine customisation, tested without a scene.
##
##   godot --headless --path . --script tools/loadout_check.gd
##
## Every number these checks assert is a balance threshold, which CLAUDE.md
## says must have a test or it is invisible. The ones worth reading twice are
## the role tradeoffs at the bottom: they are the promise the system makes —
## melee pays for reach with damage, artillery pays for damage with reach and
## a hole it cannot cover.

const RULES := "res://data/gameplay/machines.tres"
const MASS := "res://data/gameplay/mass.tres"
const LOADOUT_DIR := "res://data/machines/loadouts/"
const PARTS_DIR := "res://data/machines/parts/"
const CHASSIS_DIR := "res://data/machines/chassis/"

var _failed := 0
var _rules: MachineRules
var _spec := {}


func _initialize() -> void:
	print("SENTINEL — machine customisation checks\n")
	_rules = load(RULES)
	for f in DirAccess.get_files_at(LOADOUT_DIR):
		if f.ends_with(".tres"):
			var l: MachineLoadout = load(LOADOUT_DIR + f)
			_spec[String(l.id)] = LoadoutResolver.resolve(l, _rules)
	_fit()
	_arithmetic()
	_roles()
	_tradeoffs()
	_affordable()
	print("")
	if _failed == 0:
		print("ALL CHECKS PASSED")
	else:
		print("%d CHECK(S) FAILED" % _failed)
	quit(_failed)


func _ok(name: String, cond: bool, detail: String) -> void:
	if not cond:
		_failed += 1
	print("  %s  %s  %s" % ["PASS" if cond else "FAIL", name.rpad(40), detail])


func _part(id: String) -> MachinePart:
	return load(PARTS_DIR + id + ".tres")


func _chassis(id: String) -> MachineChassis:
	return load(CHASSIS_DIR + id + ".tres")


func _hp(slot: int, size: int) -> MachineHardpoint:
	var h := MachineHardpoint.new()
	h.id = &"t"
	h.slot = slot
	h.max_size = size
	return h


# --- what fits where --------------------------------------------------------
func _fit() -> void:
	print("hardpoints")
	var W := MachineHardpoint.Slot.WEAPON
	var A := MachineHardpoint.Slot.ARMOUR
	var LIGHT := MachineHardpoint.Size.LIGHT
	var MED := MachineHardpoint.Size.MEDIUM
	var HEAVY := MachineHardpoint.Size.HEAVY

	_ok("a light weapon fits a heavy slot",
		LoadoutResolver.fits(_part("autocannon"), _hp(W, HEAVY)), "autocannon in HEAVY")
	_ok("a heavy weapon does not fit a medium slot",
		not LoadoutResolver.fits(_part("railgun"), _hp(W, MED)), "railgun refused by MEDIUM")
	_ok("armour does not fit a weapon slot",
		not LoadoutResolver.fits(_part("plate_light"), _hp(W, LIGHT)), "kind must match")
	_ok("a weapon does not fit an armour slot",
		not LoadoutResolver.fits(_part("autocannon"), _hp(A, HEAVY)), "kind must match")

	# A bad loadout must SAY so rather than quietly building something wrong.
	var bad := MachineLoadout.new()
	bad.id = &"BAD"
	bad.chassis = _chassis("warden")
	var fitted: Array[MachinePart] = [_part("railgun"), null, null, null]
	bad.fitted = fitted
	var bs := LoadoutResolver.resolve(bad, _rules)
	_ok("an illegal fit is reported, not silently dropped",
		not bs.is_valid() and bs.errors[0].contains("RAILGUN"), bs.errors[0] if bs.errors else "—")
	_ok("every catalogue loadout is legal", _all_valid(), "%d loadouts" % _spec.size())


func _all_valid() -> bool:
	for id in _spec:
		if not _spec[id].is_valid():
			print("      %s: %s" % [id, ", ".join(_spec[id].errors)])
			return false
	return true


# --- the sums ---------------------------------------------------------------
func _arithmetic() -> void:
	print("\nresolved stats")
	var frame := _chassis("warden")
	var l := MachineLoadout.new()
	l.id = &"SUM"
	l.chassis = frame
	var fitted: Array[MachinePart] = [_part("coil_rifle"), null, _part("plate_light"), null]
	l.fitted = fitted
	var s := LoadoutResolver.resolve(l, _rules)
	var want_mass: float = frame.base_mass + _part("coil_rifle").mass + _part("plate_light").mass
	_ok("mass is the frame plus every part", is_equal_approx(s.mass, want_mass),
		"%.0f = %.0f frame + %.0f parts" % [s.mass, frame.base_mass, s.part_mass])
	_ok("an empty hardpoint is legal and costs nothing",
		s.is_valid() and s.weapons.size() == 1, "2 of 4 hardpoints filled")

	# Armour is damage reduction, not hit points. That is what makes plating
	# worth more against a swarm of small bites than against one big shell.
	var bare := LoadoutResolver.resolve(_bare(frame), _rules)
	_ok("armour reduces incoming damage",
		s.damage_after_armour(10.0, _rules) < bare.damage_after_armour(10.0, _rules),
		"%.2f vs %.2f of 10 damage"
			% [s.damage_after_armour(10.0, _rules), bare.damage_after_armour(10.0, _rules)])
	var wall := MachineSpec.new()
	wall.armour = 10000.0
	_ok("damage reduction is capped",
		is_equal_approx(wall.damage_after_armour(10.0, _rules),
			10.0 * (1.0 - _rules.max_damage_reduction)),
		"%.2f gets through at absurd armour" % wall.damage_after_armour(10.0, _rules))

	# Overloading a frame must cost speed and nothing else. If it blocked the
	# build it would be a wall, and the choice would disappear.
	var over: MachineSpec = _spec["OVERGUN"]
	_ok("overloading is flagged", over.overloaded,
		"%.0f parts on a %.0f capacity frame" % [over.part_mass, over.loadout_capacity()])
	_ok("overloading still builds", over.is_valid(), "legal, just slow")
	_ok("overloading costs speed", over.speed_penalty < 1.0,
		"%.0f%% speed" % (over.speed_penalty * 100.0))
	_ok("overloading never stops a machine dead",
		over.speed_penalty >= _rules.min_speed_fraction and over.speed_mps > 0.0,
		"%.2f m/s, floor %.0f%%" % [over.speed_mps, _rules.min_speed_fraction * 100.0])


func _bare(frame: MachineChassis) -> MachineLoadout:
	var l := MachineLoadout.new()
	l.id = &"BARE"
	l.chassis = frame
	l.normalise()
	return l


# --- what the player is choosing --------------------------------------------
func _roles() -> void:
	print("\nroles")
	var want := {
		"SKIRMISHER": MachineSpec.Role.RANGED,
		"LANCER": MachineSpec.Role.RANGED,
		"BREAKER": MachineSpec.Role.MELEE,
		"VANGUARD": MachineSpec.Role.MIXED,
		"MORTAR_WALKER": MachineSpec.Role.ARTILLERY,
		"SIEGE_BATTERY": MachineSpec.Role.ARTILLERY,
		"OVERGUN": MachineSpec.Role.RANGED,
		"WATCHER": MachineSpec.Role.UNARMED,
	}
	var wrong := 0
	for id in want:
		if not _spec.has(id) or _spec[id].role() != want[id]:
			wrong += 1
			print("      %s reads as %s" % [id, _spec[id].role_name() if _spec.has(id) else "missing"])
	_ok("every loadout reads as the role it was built for", wrong == 0,
		"%d loadouts" % want.size())

	# The whole point of the request: a player must be able to field an army of
	# each shape, or a mix. If any of these is empty the catalogue has a hole.
	for role in [MachineSpec.Role.MELEE, MachineSpec.Role.RANGED,
			MachineSpec.Role.ARTILLERY, MachineSpec.Role.MIXED]:
		var names := _with_role(role)
		_ok("a %s army is fieldable" % _role_name(role), names.size() > 0,
			", ".join(names) if names else "NOTHING IN THE CATALOGUE")


func _role_name(role: int) -> String:
	return ["unarmed", "melee", "ranged", "artillery", "mixed"][role]


func _with_role(role: int) -> PackedStringArray:
	var out := PackedStringArray()
	for id in _spec:
		if _spec[id].role() == role:
			out.append(_spec[id].display_name)
	out.sort()
	return out


# --- the tradeoffs the roles promise ----------------------------------------
func _tradeoffs() -> void:
	print("\ntradeoffs")
	var melee: MachineSpec = _spec["BREAKER"]
	var ranged: MachineSpec = _spec["LANCER"]
	var arty: MachineSpec = _spec["MORTAR_WALKER"]

	# Melee buys damage with the trip. If it did not out-damage direct fire per
	# mass, nothing would ever be worth walking into contact for.
	_ok("melee out-damages ranged per mass",
		melee.dps() / melee.mass > ranged.dps() / ranged.mass,
		"%.2f vs %.2f dps per mass"
			% [melee.dps() / melee.mass, ranged.dps() / ranged.mass])
	_ok("melee gives up all reach", melee.max_range_m() <= _rules.melee_reach_m,
		"%.1f m" % melee.max_range_m())

	# Artillery buys reach with damage AND with a hole it cannot cover itself.
	_ok("artillery outranges direct fire", arty.max_range_m() > ranged.max_range_m(),
		"%.0f m vs %.0f m" % [arty.max_range_m(), ranged.max_range_m()])
	_ok("artillery pays for it in damage",
		arty.dps() / arty.mass < ranged.dps() / ranged.mass,
		"%.2f vs %.2f dps per mass" % [arty.dps() / arty.mass, ranged.dps() / ranged.mass])
	_ok("artillery has a dead zone", arty.min_engage_m() > 0.0,
		"blind inside %.0f m" % arty.min_engage_m())
	_ok("nothing else has one",
		is_equal_approx(ranged.min_engage_m(), 0.0) and is_equal_approx(melee.min_engage_m(), 0.0),
		"melee %.0f m, ranged %.0f m" % [melee.min_engage_m(), ranged.min_engage_m()])

	# Mixed covers both bands, and should not be free: it must lose to the
	# specialist at what the specialist is for, or specialising is pointless.
	var mixed: MachineSpec = _spec["VANGUARD"]
	_ok("a mixed machine covers every band",
		is_equal_approx(mixed.min_engage_m(), 0.0) and mixed.weapons.size() >= 2,
		"%d weapons, no dead zone" % mixed.weapons.size())
	_ok("mixed loses reach to the specialist", mixed.max_range_m() < ranged.max_range_m(),
		"%.0f m vs %.0f m" % [mixed.max_range_m(), ranged.max_range_m()])
	_ok("mixed loses damage to the brawler", mixed.dps() < melee.dps(),
		"%.1f vs %.1f dps" % [mixed.dps(), melee.dps()])

	# Artillery cannot see as far as it can shoot. That is deliberate: it makes
	# a spotter a requirement rather than a convenience.
	var watcher: MachineSpec = _spec["WATCHER"]
	_ok("artillery cannot see its own range", arty.reveal_m < arty.max_range_m(),
		"sees %.0f m, shoots %.0f m" % [arty.reveal_m, arty.max_range_m()])
	_ok("a spotter closes the gap", watcher.reveal_m > arty.max_range_m(),
		"Watcher sees %.0f m" % watcher.reveal_m)


# --- can the player actually build any of this -------------------------------
func _affordable() -> void:
	print("\nagainst the economy")
	var cfg: MassConfig = load(MASS)
	var budget := cfg.starting_mass - cfg.reserve_mass
	var cheapest := INF
	var dearest := 0.0
	for id in _spec:
		cheapest = minf(cheapest, _spec[id].mass)
		dearest = maxf(dearest, _spec[id].mass)
	_ok("something is buildable from the opening mass", cheapest <= budget,
		"cheapest %.0f, budget %.0f" % [cheapest, budget])
	_ok("nothing is unbuildable even at full size", dearest <= cfg.max_mass - cfg.reserve_mass,
		"dearest %.0f, ceiling %.0f" % [dearest, cfg.max_mass - cfg.reserve_mass])
	_ok("the catalogue spans a real range", dearest >= cheapest * 2.0,
		"%.0f to %.0f mass" % [cheapest, dearest])
