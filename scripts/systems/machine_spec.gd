class_name MachineSpec
extends RefCounted
## The numbers a machine actually fights with, after its chassis and parts have
## been added up.
##
## Plain RefCounted, like MassPool and Heightfield, so a loadout can be checked
## for balance headlessly. The sim reads this and never reads a MachineChassis
## or a MachinePart directly — which is what keeps "add a new weapon" a data
## change rather than a code change.

## Shorthand for what this machine is FOR, derived from the weapons fitted to
## it. This is the readout that tells a player they are fielding an artillery
## army rather than a melee one.
enum Role { UNARMED, MELEE, RANGED, ARTILLERY, BEAM, MIXED }

var id: StringName = &""
var display_name: String = ""

var mass: float = 0.0       ## frame plus every part; what the build costs
var part_mass: float = 0.0  ## just the parts, for the overload check
var max_hp: float = 0.0
var armour: float = 0.0
## Regenerating layer in front of the hull. See MachinePart.shield_add.
var shield: float = 0.0
var speed_mps: float = 0.0
var radius_m: float = 0.55
var reveal_m: float = 0.0
var escort_radius_m: float = 6.0
var escort_speed_mps: float = 8.0
var colour: Color = Color.WHITE
var model: String = ""

## Part capacity of the frame this was built on, kept so a check can say how
## far over the line an overloaded machine is without re-reading the chassis.
var part_capacity: float = 0.0
var overloaded: bool = false
var speed_penalty: float = 1.0

## One entry per fitted weapon: family, damage, range_m, min_range_m,
## cooldown_s, splash_m, source (the part id) and socket (where it is bolted).
var weapons: Array[Dictionary] = []

## Reasons this loadout is not legal. Empty means it is buildable.
var errors: PackedStringArray = PackedStringArray()


func loadout_capacity() -> float:
	return part_capacity


func is_valid() -> bool:
	return errors.is_empty()


func role() -> Role:
	var seen := {}
	for w in weapons:
		seen[w.family] = true
	if seen.is_empty():
		return Role.UNARMED
	if seen.size() > 1:
		return Role.MIXED
	match seen.keys()[0]:
		MachinePart.Family.MELEE:
			return Role.MELEE
		MachinePart.Family.ARTILLERY:
			return Role.ARTILLERY
		MachinePart.Family.BEAM:
			return Role.BEAM
		_:
			return Role.RANGED


func role_name() -> String:
	return ["Unarmed", "Melee", "Ranged", "Artillery", "Beam", "Mixed"][role()]


## Damage per second with every weapon firing at a target all of them can hit.
## The honest headline number for comparing two loadouts.
func dps() -> float:
	var total := 0.0
	for w in weapons:
		# A BEAM's `damage` is ALREADY per second — dividing it by a cooldown
		# it does not have would have reported a laser as doing twice its real
		# output, on the one readout players use to compare two loadouts.
		if int(w.get("family", 0)) == MachinePart.Family.BEAM:
			total += w.damage
		else:
			total += w.damage / maxf(0.01, w.cooldown_s)
	return total


## Furthest any weapon can reach, which is how far the machine wants to stand.
func max_range_m() -> float:
	var r := 0.0
	for w in weapons:
		r = maxf(r, w.range_m)
	return r


## Closest a target can be before at least one weapon can still answer. An
## artillery-only machine has a hole here, and that hole is the point of it.
func min_engage_m() -> float:
	if weapons.is_empty():
		return 0.0
	var m := INF
	for w in weapons:
		m = minf(m, w.min_range_m)
	return m


## Damage that gets through this machine's plating.
func damage_after_armour(raw: float, rules: MachineRules) -> float:
	if armour <= 0.0 or rules == null:
		return raw
	var reduction := armour / (armour + maxf(0.001, rules.armour_softening))
	return raw * (1.0 - minf(reduction, rules.max_damage_reduction))


## Effective hit points against a given attack — what the plating is really
## buying, in the only unit the player can compare against mass.
func effective_hp(rules: MachineRules) -> float:
	var through := damage_after_armour(1.0, rules)
	return max_hp / maxf(0.0001, through)
