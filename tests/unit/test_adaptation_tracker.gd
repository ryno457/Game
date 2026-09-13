extends GutTest
## The corrected adaptation rule.
##
## The first case is the regression this file exists for: the original rule
## fell through to `turret >= drone`, which is true at 0 >= 0, so a player who
## did nothing was counter-adapted for turret play every single wave.

var rules: AdaptationRules
var tracker: AdaptationTracker


func before_each() -> void:
	rules = load("res://data/adaptation/default_rules.tres").duplicate()
	tracker = AdaptationTracker.new(rules)


func _reliance(turret: float, drone: float, trench: float) -> Dictionary:
	return {&"turret": turret, &"drone": drone, &"trench": trench}


func test_idle_player_is_not_adapted_against() -> void:
	assert_eq(tracker.resolve(_reliance(0.0, 0.0, 0.0)), &"",
		"an idle wave must teach the hive nothing")


func test_barely_active_wave_is_below_the_floor() -> void:
	assert_eq(tracker.resolve(_reliance(3.0, 1.0, 0.0)), &"")


func test_committed_turret_defence_grows_chitin() -> void:
	assert_eq(tracker.resolve(_reliance(30.0, 2.0, 0.0)), &"chitin_plating")


func test_committed_drone_swarm_grows_sprint_glands() -> void:
	assert_eq(tracker.resolve(_reliance(1.0, 25.0, 0.0)), &"sprint_glands")


func test_committed_trench_digging_grows_burrowing() -> void:
	assert_eq(tracker.resolve(_reliance(0.0, 2.0, 20.0)), &"burrowing")


func test_evenly_mixed_play_is_not_punished() -> void:
	assert_eq(tracker.resolve(_reliance(10.0, 10.0, 10.0)), &"",
		"switching tactics must be a real defence, not a slower loss")


func test_dead_tie_adapts_nothing() -> void:
	assert_eq(tracker.resolve(_reliance(15.0, 15.0, 0.0)), &"")


func test_mixed_but_clearly_led_still_adapts() -> void:
	# 12 / 25 = 48%, over the 40% share floor.
	assert_eq(tracker.resolve(_reliance(12.0, 8.0, 5.0)), &"chitin_plating")


func test_leader_under_share_floor_adapts_nothing() -> void:
	# 9 / 25 = 36%, under the 40% share floor.
	assert_eq(tracker.resolve(_reliance(9.0, 8.0, 8.0)), &"")


func test_exactly_at_reliance_floor_adapts() -> void:
	assert_eq(tracker.resolve(_reliance(rules.min_reliance_s, 0.0, 0.0)), &"chitin_plating")


func test_just_under_reliance_floor_does_not() -> void:
	assert_eq(tracker.resolve(_reliance(rules.min_reliance_s - 0.1, 0.0, 0.0)), &"")


func test_stacks_accumulate_and_report() -> void:
	tracker.apply(_reliance(30.0, 0.0, 0.0))
	tracker.apply(_reliance(30.0, 0.0, 0.0))
	assert_eq(tracker.stack_count(&"chitin_plating"), 2)
	assert_string_contains(tracker.describe(), "Chitin Plating II")


func test_chitin_resistance_floors_and_never_inverts() -> void:
	for i in 20:
		tracker.stacks[&"chitin_plating"] = i
		var m := tracker.hostile_damage_taken_multiplier()
		assert_between(m, rules.chitin_resist_floor, 1.0,
			"damage multiplier must stay within [floor, 1] at %d stacks" % i)


func test_burrowing_only_ignores_terrain_once_grown() -> void:
	assert_false(tracker.hostiles_ignore_terrain())
	tracker.apply(_reliance(0.0, 0.0, 30.0))
	assert_true(tracker.hostiles_ignore_terrain())
