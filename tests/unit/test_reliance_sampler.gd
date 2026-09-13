extends GutTest
## Reliance must be one currency. The prototype compared deploy counts against
## dig seconds, which is not a comparison.

var sampler: RelianceSampler


func before_each() -> void:
	sampler = RelianceSampler.new()


func test_static_platform_reads_as_turret_play() -> void:
	sampler.sample_engagement(true, 2.0)
	assert_eq(sampler.totals()[&"turret"], 2.0)
	assert_eq(sampler.totals()[&"drone"], 0.0)


func test_mobile_platform_reads_as_drone_play() -> void:
	sampler.sample_engagement(false, 2.0)
	assert_eq(sampler.totals()[&"drone"], 2.0)


func test_all_three_tactics_share_one_unit() -> void:
	sampler.sample_engagement(true, 1.0)
	sampler.sample_engagement(false, 1.0)
	sampler.sample_digging(1.0)
	assert_eq(sampler.total(), 3.0, "one second of any tactic must weigh the same")


func test_shares_normalize() -> void:
	sampler.sample_engagement(true, 3.0)
	sampler.sample_digging(1.0)
	assert_almost_eq(sampler.shares()[&"turret"], 0.75, 0.001)
	assert_almost_eq(sampler.shares()[&"trench"], 0.25, 0.001)


func test_idle_sampler_reports_no_shares() -> void:
	assert_eq(sampler.shares(), {}, "no activity must not imply a tactic")


func test_reset_clears_between_waves() -> void:
	sampler.sample_digging(5.0)
	sampler.reset()
	assert_eq(sampler.total(), 0.0)
