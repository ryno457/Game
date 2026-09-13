class_name RelianceSampler
extends RefCounted
## Accumulates how hard the player leaned on each tactic during a wave.
##
## The unit is UNIT-SECONDS: one armed unit engaged for one second, or one
## digger carving for one second, is 1.0. Every tactic is measured the same
## way, which is the whole point — the prototype compared deploy counts to dig
## seconds and the comparison was meaningless.
##
## What counts:
##   turret — a STATIC armed unit, or a STATIONARY gun chassis, with a hostile
##            in range. A chassis on the move is playing mobile, not defending.
##   drone  — a MOBILE armed unit with a hostile in range.
##   trench — a digger actively carving.
##
## What deliberately does not count: salvage drones. Mining is not a combat
## tactic, and counting it read every economic opening as a drone swarm.

var _s: Dictionary = {&"turret": 0.0, &"drone": 0.0, &"trench": 0.0}


func sample_engagement(is_static_platform: bool, delta: float) -> void:
	var key := &"turret" if is_static_platform else &"drone"
	_s[key] += delta


func sample_digging(delta: float) -> void:
	_s[&"trench"] += delta


func totals() -> Dictionary:
	return _s.duplicate()


func total() -> float:
	var n := 0.0
	for v in _s.values():
		n += v
	return n


## Normalized 0-1 share per tactic, for the HUD readout. Empty when idle.
func shares() -> Dictionary:
	var t := total()
	if is_zero_approx(t):
		return {}
	var out := {}
	for k in _s:
		out[k] = _s[k] / t
	return out


func reset() -> void:
	for k in _s:
		_s[k] = 0.0
