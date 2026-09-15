extends SceneTree
## Writes the machine customisation catalogue as .tres.
##
##   godot --headless --path . --script tools/build_machine_data.gd
##
## The catalogue is data, but hand-writing .tres is how ext_resource ids go
## wrong silently. Building it from one script keeps every chassis, part and
## loadout consistent and makes "add a weapon family" a five-line edit here
## rather than a new file format to get right by hand.

const CHASSIS_DIR := "res://data/machines/chassis/"
const PARTS_DIR := "res://data/machines/parts/"
const LOADOUT_DIR := "res://data/machines/loadouts/"
const OPTIONS_DIR := "res://data/gameplay/build_options/"
const RULES_PATH := "res://data/gameplay/machines.tres"

const W := MachineHardpoint.Slot.WEAPON
const A := MachineHardpoint.Slot.ARMOUR
const M := MachineHardpoint.Slot.MOBILITY
const S := MachineHardpoint.Slot.SENSOR
const U := MachineHardpoint.Slot.UTILITY
const LIGHT := MachineHardpoint.Size.LIGHT
const MED := MachineHardpoint.Size.MEDIUM
const HEAVY := MachineHardpoint.Size.HEAVY

var _parts := {}
var _chassis := {}


func _initialize() -> void:
	for d in [CHASSIS_DIR, PARTS_DIR, LOADOUT_DIR]:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(d))
	_rules()
	_make_parts()
	_make_chassis()
	_make_loadouts()
	print("machine catalogue written")
	quit(0)


func _save(res: Resource, path: String) -> void:
	var err := ResourceSaver.save(res, path)
	if err != OK:
		push_error("could not write %s (%d)" % [path, err])
	else:
		print("  ", path)


func _rules() -> void:
	var r := MachineRules.new()
	r.armour_softening = 40.0
	r.max_damage_reduction = 0.75
	r.min_speed_fraction = 0.4
	r.overload_bite = 1.0
	r.melee_reach_m = 1.6
	_save(r, RULES_PATH)


func _hp(id: String, slot: int, size: int, socket := "", aims := false) -> MachineHardpoint:
	var h := MachineHardpoint.new()
	h.id = StringName(id)
	h.slot = slot
	h.max_size = size
	h.socket = socket
	h.aims = aims
	return h


# --- parts ------------------------------------------------------------------
func _part(id: String, name: String, slot: int, size: int, mass: float, desc: String) -> MachinePart:
	var p := MachinePart.new()
	p.id = StringName(id)
	p.display_name = name
	p.slot = slot
	p.size = size
	p.mass = mass
	p.description = desc
	_parts[id] = p
	return p


func _weapon(p: MachinePart, fam: int, dmg: float, rng: float, cd: float,
		min_r := 0.0, splash := 0.0) -> MachinePart:
	p.family = fam
	p.damage = dmg
	p.range_m = rng
	p.cooldown_s = cd
	p.min_range_m = min_r
	p.splash_m = splash
	return p


func _make_parts() -> void:
	print("parts")
	var melee := MachinePart.Family.MELEE
	var ranged := MachinePart.Family.RANGED
	var arty := MachinePart.Family.ARTILLERY

	# Melee — everything it touches dies fast; getting there is the problem.
	_weapon(_part("RAM_SPIKE", "Ram Spike", W, LIGHT, 3.0,
		"A spike on a piston. Cheap, light, and lethal at arm's length."),
		melee, 22.0, 0.0, 0.9)
	_weapon(_part("CLEAVER_ARM", "Cleaver Arm", W, MED, 6.0,
		"A powered blade. The best damage per mass in the catalogue, if you can close."),
		melee, 46.0, 0.0, 1.2)
	_weapon(_part("PILE_DRIVER", "Pile Driver", W, HEAVY, 11.0,
		"A slow hammer that splashes. Turns a swarm that reached you into a problem it regrets."),
		melee, 110.0, 0.0, 2.2, 0.0, 1.2)

	# Ranged — the default answer, and the only family with no dead zone.
	_weapon(_part("AUTOCANNON", "Autocannon", W, LIGHT, 4.0,
		"Fast, short, dependable. The weapon you fit when you have one light slot left."),
		ranged, 11.0, 9.0, 0.5)
	_weapon(_part("ARC_REPEATER", "Arc Repeater", W, MED, 6.0,
		"Low damage, almost no cooldown, a little splash. Shreds crowds, embarrasses armour."),
		ranged, 9.0, 8.0, 0.22, 0.0, 0.8)
	_weapon(_part("COIL_RIFLE", "Coil Rifle", W, MED, 7.0,
		"Direct fire that outranges everything that has to reach you."),
		ranged, 30.0, 14.0, 1.1)
	_weapon(_part("RAILGUN", "Railgun", W, HEAVY, 12.0,
		"One heavy shot every few seconds at extreme direct-fire range."),
		ranged, 85.0, 22.0, 2.6)

	# Artillery — outranges everything and cannot defend itself. Both halves of
	# that sentence are the point: min_range_m is the hole the escort fills.
	_weapon(_part("MORTAR_POD", "Mortar Pod", W, MED, 8.0,
		"Indirect fire with a wide splash and a hole inside seven metres."),
		arty, 40.0, 20.0, 2.4, 7.0, 3.0)
	_weapon(_part("SIEGE_HOWITZER", "Siege Howitzer", W, HEAVY, 15.0,
		"Reaches further than anything can see unaided. Blind inside twelve metres."),
		arty, 95.0, 34.0, 4.2, 12.0, 5.0)

	# Armour — hit points and damage reduction, paid for in speed.
	var pl := _part("PLATE_LIGHT", "Light Plating", A, LIGHT, 3.0,
		"A little steel. Cheap insurance against chip damage.")
	pl.hp_add = 30.0
	pl.armour_add = 6.0
	pl.speed_mult = 0.94

	var pm := _part("PLATE_MEDIUM", "Composite Plating", A, MED, 6.0,
		"Real protection. You will feel the weight in the convoy.")
	pm.hp_add = 70.0
	pm.armour_add = 16.0
	pm.speed_mult = 0.88

	var ab := _part("ABLATIVE_SLAB", "Ablative Slab", A, HEAVY, 11.0,
		"Walks through a swarm. Does not walk quickly.")
	ab.hp_add = 140.0
	ab.armour_add = 34.0
	ab.speed_mult = 0.78

	# Mobility — speed, or the refusal of it.
	var sl := _part("SPRINT_LEGS", "Sprint Legs", M, LIGHT, 3.0,
		"Light limbs. Gets a scout to the edge of the fog and back.")
	sl.speed_add_mps = 2.2

	var st := _part("STRIDER_LEGS", "Strider Legs", M, MED, 5.0,
		"Long stride, a little frame reinforcement. The default walker.")
	st.speed_add_mps = 3.4
	st.hp_add = 10.0

	var tr := _part("HEAVY_TREADS", "Heavy Treads", M, MED, 7.0,
		"Slower than legs, but they carry plating without complaining.")
	tr.speed_add_mps = -0.6
	tr.hp_add = 45.0
	tr.armour_add = 8.0

	# Sensors — fog is the real constraint on long-range weapons.
	var sa := _part("SPOTTER_ARRAY", "Spotter Array", S, LIGHT, 3.0,
		"Sees twelve metres. Enough for direct fire to use its whole range.")
	sa.reveal_m = 12.0

	var rm := _part("RADAR_MAST", "Radar Mast", S, HEAVY, 8.0,
		"Sees twenty-six metres. Artillery is blind without one of these nearby.")
	rm.reveal_m = 26.0
	rm.hp_add = 10.0
	rm.model = "radar"

	# Utility — the odds and ends that make a build work.
	var bs := _part("BRACE_STRUTS", "Brace Struts", U, MED, 4.0,
		"Frame bracing. Hit points without the armour tax on speed.")
	bs.hp_add = 50.0
	bs.speed_mult = 0.95

	var spl := _part("SPOTTING_LINK", "Spotting Link", U, MED, 4.0,
		"A modest eye in a slot a weapon cannot use anyway.")
	spl.reveal_m = 9.0

	for id in _parts:
		_save(_parts[id], PARTS_DIR + String(id).to_lower() + ".tres")


# --- chassis ----------------------------------------------------------------
func _make_chassis() -> void:
	print("chassis")

	var skiff := MachineChassis.new()
	skiff.id = &"SKIFF"
	skiff.display_name = "Skiff"
	skiff.description = "A light frame with one weapon and somewhere to put an eye."
	skiff.base_mass = 4.0
	skiff.base_hp = 45.0
	skiff.base_speed_mps = 5.6
	skiff.radius_m = 0.45
	skiff.part_capacity = 10.0
	skiff.escort_radius_m = 9.0
	skiff.escort_speed_mps = 10.0
	skiff.model = "guard"
	skiff.colour = Color(0.42, 0.92, 0.78)
	skiff.hardpoints = [
		_hp("w0", W, LIGHT, "weapon_arm", true),
		_hp("s0", S, LIGHT),
		_hp("m0", M, LIGHT),
	]
	_chassis["SKIFF"] = skiff

	var warden := MachineChassis.new()
	warden.id = &"WARDEN"
	warden.display_name = "Warden"
	warden.description = "Two weapons, plating and legs. The frame most armies are made of."
	warden.base_mass = 7.0
	warden.base_hp = 90.0
	warden.base_armour = 4.0
	warden.base_speed_mps = 4.2
	warden.radius_m = 0.55
	warden.part_capacity = 20.0
	warden.escort_radius_m = 6.0
	warden.escort_speed_mps = 8.0
	warden.model = "guard"
	warden.colour = Color(0.31, 0.89, 0.76)
	warden.hardpoints = [
		_hp("w0", W, MED, "weapon_arm", true),
		_hp("w1", W, LIGHT, "weapon_arm", true),
		_hp("a0", A, MED),
		_hp("m0", M, MED),
	]
	_chassis["WARDEN"] = warden

	var bastion := MachineChassis.new()
	bastion.id = &"BASTION"
	bastion.display_name = "Bastion"
	bastion.description = "A heavy weapon mount that barely moves. Where the big guns go."
	bastion.base_mass = 12.0
	bastion.base_hp = 140.0
	bastion.base_armour = 8.0
	bastion.base_speed_mps = 2.8
	bastion.radius_m = 0.75
	bastion.part_capacity = 30.0
	bastion.escort_radius_m = 4.5
	bastion.escort_speed_mps = 6.0
	bastion.model = "turret"
	bastion.colour = Color(0.92, 0.64, 0.33)
	bastion.hardpoints = [
		_hp("w0", W, HEAVY, "turret_head", true),
		_hp("w1", W, MED, "turret_head", true),
		_hp("a0", A, HEAVY),
		_hp("u0", U, MED),
	]
	_chassis["BASTION"] = bastion

	var vane := MachineChassis.new()
	vane.id = &"VANE"
	vane.display_name = "Vane"
	vane.description = "No weapon hardpoint at all. It exists to see, which is what artillery needs."
	vane.base_mass = 6.0
	vane.base_hp = 70.0
	vane.base_speed_mps = 3.6
	vane.radius_m = 0.6
	vane.part_capacity = 16.0
	vane.escort_radius_m = 5.0
	vane.escort_speed_mps = 7.0
	vane.model = "radar"
	vane.colour = Color(0.55, 0.74, 0.98)
	vane.hardpoints = [
		_hp("s0", S, HEAVY, "radar_dish", true),
		_hp("u0", U, MED),
		_hp("a0", A, LIGHT),
	]
	_chassis["VANE"] = vane

	for id in _chassis:
		_save(_chassis[id], CHASSIS_DIR + String(id).to_lower() + ".tres")


# --- loadouts ---------------------------------------------------------------
func _loadout(id: String, name: String, chassis_id: String, part_ids: Array,
		desc: String) -> MachineLoadout:
	var l := MachineLoadout.new()
	l.id = StringName(id)
	l.display_name = name
	l.description = desc
	l.chassis = _chassis[chassis_id]
	var fitted: Array[MachinePart] = []
	for pid in part_ids:
		fitted.append(null if pid == "" else _parts[pid])
	l.fitted = fitted
	return l


func _make_loadouts() -> void:
	print("loadouts")
	var rules: MachineRules = load(RULES_PATH)
	var made: Array[MachineLoadout] = [
		_loadout("SKIRMISHER", "Skirmisher", "SKIFF",
			["AUTOCANNON", "SPOTTER_ARRAY", "SPRINT_LEGS"],
			"Fast, sees far, hits lightly. The machine that finds the debris."),
		_loadout("LANCER", "Lancer", "WARDEN",
			["COIL_RIFLE", "AUTOCANNON", "PLATE_LIGHT", "STRIDER_LEGS"],
			"Direct fire at two ranges behind light plating. The line infantry."),
		_loadout("BREAKER", "Breaker", "WARDEN",
			["CLEAVER_ARM", "RAM_SPIKE", "PLATE_MEDIUM", "STRIDER_LEGS"],
			"Closes and kills. Everything it carries needs it to be standing next to you."),
		_loadout("VANGUARD", "Vanguard", "WARDEN",
			["CLEAVER_ARM", "AUTOCANNON", "PLATE_LIGHT", "STRIDER_LEGS"],
			"A blade and a gun. No dead zone at any range it can reach."),
		_loadout("MORTAR_WALKER", "Mortar Walker", "WARDEN",
			["MORTAR_POD", "", "PLATE_LIGHT", "STRIDER_LEGS"],
			"Indirect fire on legs. Helpless inside seven metres — escort it."),
		_loadout("SIEGE_BATTERY", "Siege Battery", "BASTION",
			["SIEGE_HOWITZER", "", "ABLATIVE_SLAB", "BRACE_STRUTS"],
			"Thirty-four metres of reach and twelve metres of blindness."),
		_loadout("OVERGUN", "Overgun", "BASTION",
			["RAILGUN", "COIL_RIFLE", "ABLATIVE_SLAB", "BRACE_STRUTS"],
			"Deliberately overloaded: everything the frame can hold and then some."),
		_loadout("WATCHER", "Watcher", "VANE",
			["RADAR_MAST", "SPOTTING_LINK", "PLATE_LIGHT"],
			"Unarmed. Its whole job is making the artillery's range mean something."),
	]

	for l in made:
		_save(l, LOADOUT_DIR + String(l.id).to_lower() + ".tres")
		var spec := LoadoutResolver.resolve(l, rules)
		var opt := BuildOption.new()
		opt.id = l.id
		opt.display_name = l.display_name
		opt.description = l.description
		opt.loadout = l
		opt.mass_cost = spec.mass
		opt.max_hp = spec.max_hp
		opt.radius_m = spec.radius_m
		opt.speed_mps = spec.speed_mps
		opt.colour = spec.colour
		opt.model = spec.model
		opt.reveal_m = spec.reveal_m
		opt.escort_radius_m = spec.escort_radius_m
		opt.escort_speed_mps = spec.escort_speed_mps
		opt.damage = spec.dps()          # presentation only; _fire reads the spec
		opt.range_m = spec.max_range_m()
		# Aim the socket of the first weapon that can be aimed, so a mortar
		# walker turns its pod toward what it is shelling.
		for w in spec.weapons:
			if w.aims and String(w.socket) != "":
				opt.aim_node = w.socket
				break
		if opt.aim_node == "" and l.chassis.hardpoints.size() > 0:
			for h in l.chassis.hardpoints:
				if h.aims and h.socket != "":
					opt.aim_node = h.socket
					break
		_save(opt, OPTIONS_DIR + String(l.id).to_lower() + ".tres")
		print("    %-14s %-9s %5.1f mass  %5.0f hp  %5.1f dps  %4.1f m%s"
			% [l.display_name, spec.role_name(), spec.mass, spec.max_hp, spec.dps(),
				spec.max_range_m(), "  OVERLOADED" if spec.overloaded else ""])
		if not spec.is_valid():
			push_error("%s: %s" % [l.id, ", ".join(spec.errors)])
