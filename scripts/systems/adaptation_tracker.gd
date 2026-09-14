class_name AdaptationTracker
extends RefCounted
## Decides what the hive learns at the end of each wave, and holds the stacks.
##
## Stacks persist across missions within a biodome.

## Emitted with an empty id when the hive could not read the player this wave.
## The owning node forwards this to EventBus.hive_adapted; see Heightfield for
## why this is not emitted on the bus directly.
signal adapted(adaptation_id: StringName, stacks: int)

var rules: AdaptationRules
var stacks: Dictionary = {}   # adaptation_id -> int

func _init(adaptation_rules: AdaptationRules) -> void:
	rules = adaptation_rules


## Read a wave's reliance and return the adaptation id it earns, or &"" for
## none. Three guards, in order:
##   · not enough reliance to read      -> nothing (passive wave)
##   · no tactic holds a clear majority -> nothing (genuinely mixed play)
##   · exact tie at the top             -> nothing
##
## The rule this replaces had none of them. With zero activity its
## `turret >= drone` branch held (0 >= 0), so a player who did nothing at all
## was handed Chitin Plating every single wave.
func resolve(reliance: Dictionary) -> StringName:
	var ranked: Array = []
	for key in rules.counters:
		ranked.append([key, float(reliance.get(key, 0.0))])
	if ranked.size() < 2:
		return &""
	ranked.sort_custom(func(a, b): return a[1] > b[1])

	var total := 0.0
	for entry in ranked:
		total += entry[1]

	if total < rules.min_reliance_s:
		return &""
	if ranked[0][1] / total < rules.min_share:
		return &""
	if is_equal_approx(ranked[0][1], ranked[1][1]):
		return &""

	return rules.counters[ranked[0][0]]


## Resolve, bank the stack, and announce it. Announcing matters: an adaptation
## the player cannot see reads as unfair difficulty scaling.
func apply(reliance: Dictionary) -> StringName:
	var gained := resolve(reliance)
	if gained == &"":
		adapted.emit(&"", 0)
		return &""
	stacks[gained] = stacks.get(gained, 0) + 1
	adapted.emit(gained, stacks[gained])
	return gained


func stack_count(adaptation_id: StringName) -> int:
	return stacks.get(adaptation_id, 0)


func hostile_bonus_hp() -> float:
	return stack_count(&"chitin_plating") * rules.chitin_bonus_hp


func hostile_bonus_speed() -> float:
	return stack_count(&"sprint_glands") * rules.sprint_bonus_mps


## Multiplier applied to incoming damage against hostiles.
func hostile_damage_taken_multiplier() -> float:
	var n := stack_count(&"chitin_plating")
	return maxf(rules.chitin_resist_floor, 1.0 - n * rules.chitin_resist_per_stack)


func hostiles_ignore_terrain() -> bool:
	return rules.burrow_ignores_terrain and stack_count(&"burrowing") > 0


## HUD string. Empty when the hive has learned nothing yet.
func describe() -> String:
	var parts: PackedStringArray = []
	for id in stacks:
		if stacks[id] <= 0:
			continue
		var label: String = rules.display_names.get(id, String(id))
		parts.append("%s %s" % [label, "I".repeat(mini(4, stacks[id]))])
	return " · ".join(parts)
