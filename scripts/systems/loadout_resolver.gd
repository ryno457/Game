class_name LoadoutResolver
extends RefCounted
## Turns a MachineLoadout into the numbers the sim uses, and says plainly when
## a loadout does not add up.
##
## All static. There is no state to keep: the same loadout and the same rules
## always give the same spec, which is what makes it safe to resolve at load
## time and cache the result.


## Can this part go in this hardpoint? Kind must match exactly; size must fit.
static func fits(part: MachinePart, hp: MachineHardpoint) -> bool:
	if part == null or hp == null:
		return false
	return part.slot == hp.slot and int(part.size) <= int(hp.max_size)


static func resolve(loadout: MachineLoadout, rules: MachineRules) -> MachineSpec:
	var spec := MachineSpec.new()
	if loadout == null:
		spec.errors.append("no loadout")
		return spec

	spec.id = loadout.id
	spec.display_name = loadout.display_name

	var frame := loadout.chassis
	if frame == null:
		spec.errors.append("loadout '%s' has no chassis" % loadout.id)
		return spec

	spec.mass = frame.base_mass
	spec.max_hp = frame.base_hp
	spec.armour = frame.base_armour
	spec.radius_m = frame.radius_m
	spec.escort_radius_m = frame.escort_radius_m
	spec.escort_speed_mps = frame.escort_speed_mps
	spec.part_capacity = frame.part_capacity
	spec.colour = frame.colour
	spec.model = frame.model
	if spec.display_name == "":
		spec.display_name = frame.display_name

	if loadout.fitted.size() > frame.hardpoints.size():
		spec.errors.append("%d parts fitted to %d hardpoints"
			% [loadout.fitted.size(), frame.hardpoints.size()])

	var speed := frame.base_speed_mps
	var speed_mult := 1.0

	for i in frame.hardpoints.size():
		var hp := frame.hardpoints[i]
		var part: MachinePart = loadout.fitted[i] if i < loadout.fitted.size() else null
		if part == null:
			continue  # an empty hardpoint is a lighter, cheaper machine
		if not fits(part, hp):
			spec.errors.append("'%s' does not fit hardpoint '%s'" % [part.id, hp.id])
			continue

		spec.part_mass += part.mass
		spec.max_hp += part.hp_add
		spec.armour += part.armour_add
		spec.shield += part.shield_add
		spec.reveal_m = maxf(spec.reveal_m, part.reveal_m)
		speed += part.speed_add_mps
		speed_mult *= part.speed_mult

		if part.is_weapon():
			var reach := part.range_m
			if part.family == MachinePart.Family.MELEE and rules != null:
				reach = rules.melee_reach_m
			spec.weapons.append({
				"family": part.family,
				"damage": part.damage,
				"range_m": reach,
				"min_range_m": part.min_range_m,
				"cooldown_s": part.cooldown_s,
				"splash_m": part.splash_m,
				"beam_ramp_s": part.beam_ramp_s,
				"beam_floor": part.beam_floor,
				"source": part.id,
				"socket": hp.socket,
				"aims": hp.aims,
				"model": part.model,
			})

	# Overloading is a price, not a wall. A frame carrying twice its capacity
	# still works; it just crawls, and a machine that cannot keep station with
	# the convoy is its own punishment.
	spec.mass += spec.part_mass
	if rules != null and frame.part_capacity > 0.0 and spec.part_mass > frame.part_capacity:
		spec.overloaded = true
		var over := (spec.part_mass - frame.part_capacity) / frame.part_capacity
		spec.speed_penalty = clampf(
			1.0 / (1.0 + over * rules.overload_bite), rules.min_speed_fraction, 1.0)

	spec.speed_mps = maxf(0.0, speed * speed_mult * spec.speed_penalty)
	spec.escort_speed_mps = maxf(0.0, spec.escort_speed_mps * speed_mult * spec.speed_penalty)
	return spec
