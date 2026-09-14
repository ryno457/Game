class_name WaveDirector
extends RefCounted
## Waves are triggered by what the player does, never by a clock.
##
## v1 sent a wave every 45 seconds, which fights an exploration game. Here:
## freeing a large debris piece is what wakes the hive. Attacks run while the
## drone works and stop when the piece comes free, so the player chooses when a
## fight starts and how much defence to build first.
##
## Plain RefCounted: the trigger rules are the thing worth testing, and they do
## not need a scene to be tested.

signal wave_began(source_id: StringName, intensity: float)
signal wave_ended(source_id: StringName)
signal spawn_due(count: int, intensity: float)

var cfg: WaveTable
var active_source: StringName = &""
var elapsed := 0.0

var _spawn_cd := 0.0
var _intensity := 1.0


func _init(wave_cfg: WaveTable) -> void:
	cfg = wave_cfg


func is_active() -> bool:
	return active_source != &""


## Called when the drone starts freeing a stuck piece. `intensity` scales with
## how big the piece is: a bigger prize costs a harder fight.
func begin(source_id: StringName, intensity: float) -> void:
	if is_active():
		return
	active_source = source_id
	_intensity = maxf(0.1, intensity)
	elapsed = 0.0
	# First group arrives after a beat, so the player sees the warning before
	# anything reaches them.
	_spawn_cd = cfg.interval_s * 0.25
	wave_began.emit(source_id, _intensity)


## Called when the piece comes free, or the drone is recalled off the job.
func end() -> void:
	if not is_active():
		return
	var was := active_source
	active_source = &""
	wave_ended.emit(was)


func tick(delta: float) -> void:
	if not is_active():
		return
	elapsed += delta
	_spawn_cd -= delta
	if _spawn_cd <= 0.0:
		_spawn_cd = cfg.interval_s / _intensity
		spawn_due.emit(group_size(), _intensity)


## Pressure ramps with how long the dig has been running, so a long job is
## genuinely harder than a short one.
func group_size() -> int:
	var ramp := 1.0 + elapsed / maxf(1.0, cfg.interval_s * 3.0)
	return maxi(1, int((cfg.count_base + cfg.count_per_wave) * _intensity * ramp))


func hostile_hp() -> float:
	return cfg.hp_base + cfg.hp_per_wave * _intensity * (1.0 + elapsed / 60.0)
