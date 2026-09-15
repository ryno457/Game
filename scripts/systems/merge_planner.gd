class_name MergePlanner
extends RefCounted
## What a selected group of machines can turn into.
##
## All static and free of the scene, so the rule "you need two units to make a
## bigger one" is a testable arithmetic statement rather than something buried
## in a UI callback.
##
## The rule is simply mass: a group can become any machine whose mass is no
## more than the mass standing in the group. One Skirmisher (14) can become a
## Bulwark or a Guard; two Skirmishers (28) can become a Lancer or a Breaker;
## a Lancer and a Breaker (53) can become a Siege Battery and drop the change.


## Mass standing in a group of machines.
static func pool_mass(group: Array) -> float:
	var total := 0.0
	for spec in group:
		total += (spec as MachineSpec).mass
	return total


## Everything this much mass could become, heaviest first.
##
## Includes machines lighter than the pool — converting down is legal, it just
## leaves a wreck behind. Excludes the no-op only when the group is a single
## machine already of that type, because "merge into what you already are" is
## not a choice, it is a misread tap.
static func candidates(pool: float, options: Array, specs: Dictionary,
		exclude_id: StringName = &"") -> Array:
	var out: Array = []
	for opt in options:
		var o := opt as BuildOption
		if o.id == exclude_id:
			continue
		var spec: MachineSpec = specs.get(o.id)
		if spec == null or not spec.is_valid():
			continue
		if spec.mass <= pool + 0.001:
			out.append(o)
	out.sort_custom(func(a, b):
		return (specs[a.id] as MachineSpec).mass > (specs[b.id] as MachineSpec).mass)
	return out


## The heaviest thing this pool can become, or null.
static func best(pool: float, options: Array, specs: Dictionary,
		exclude_id: StringName = &"") -> BuildOption:
	var c := candidates(pool, options, specs, exclude_id)
	return c[0] if not c.is_empty() else null


## Mass the new shape cannot use. Never destroyed — see `is_crumb` for where
## it goes.
static func leftover(pool: float, target_mass: float) -> float:
	return maxf(0.0, pool - target_mass)


## Is this leftover too small to be worth dropping on the ground?
##
## Both answers conserve mass. A real offcut becomes a wreck the drone has to
## fetch, which is what makes overshooting a merge cost a trip. A crumb goes
## straight back into the module instead, because littering the field with
## half-mass pebbles is worse than the fiction of the group carrying it home.
static func is_crumb(spare: float, rules: MergeRules) -> bool:
	return spare > 0.0 and rules != null and spare < rules.leftover_floor


## Seconds to reforge a group into `target`. Charged on the TARGET's mass, not
## the pool's: what takes time is assembling the new machine, and reusing parts
## already in machine form is what `field_work_mult` discounts.
static func work_time(target_mass: float, mass_cfg: MassConfig, rules: MergeRules) -> float:
	if mass_cfg == null:
		return 0.0
	var base := mass_cfg.build_time_for(target_mass)
	if rules == null:
		return base
	return maxf(rules.min_work_s, base * rules.field_work_mult)


## Is this a legal group to give a merge order to?
static func group_is_legal(size: int, rules: MergeRules) -> bool:
	return size >= 1 and (rules == null or size <= rules.max_group)
