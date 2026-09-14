class_name MassPool
extends RefCounted
## The module's mass, and every rule about spending it.
##
## Plain RefCounted so the economy is testable without a scene — the same
## reason Heightfield is. Presentation (the module growing and shrinking) reads
## `normalized()`; it never writes here.

signal changed(mass: float, delta: float)
signal rejected(reason: String)

var cfg: MassConfig
var mass: float = 0.0


func _init(config: MassConfig) -> void:
	cfg = config
	mass = config.starting_mass


func normalized() -> float:
	return clampf(mass / maxf(0.001, cfg.max_mass), 0.0, 1.0)


## Presentation scale for the module body.
func display_scale() -> float:
	return lerpf(cfg.scale_at_min, cfg.scale_at_max, sqrt(normalized()))


func can_afford(cost: float) -> bool:
	return mass - cost >= cfg.reserve_mass


## Spend mass to build. Returns false and explains itself rather than silently
## doing nothing — a build that fails for an invisible reason is a bug report.
func spend(cost: float) -> bool:
	if cost <= 0.0:
		return false
	if not can_afford(cost):
		rejected.emit("needs %.0f mass, %.0f available above reserve"
			% [cost, maxf(0.0, mass - cfg.reserve_mass)])
		return false
	mass -= cost
	changed.emit(mass, -cost)
	return true


## Debris and other outright gains.
func gain(amount: float) -> float:
	if amount <= 0.0:
		return 0.0
	var before := mass
	mass = minf(cfg.max_mass, mass + amount)
	var got := mass - before
	if got > 0.0:
		changed.emit(mass, got)
	return got


## Recover a destroyed unit's wreck. Lossy on purpose.
func recover(original_cost: float) -> float:
	return gain(original_cost * (1.0 - cfg.recovery_loss))


## Voluntarily scrap a live unit back into the module. Less lossy than losing
## it in a fight, so choosing to reconfigure beats being forced to.
func scrap(original_cost: float) -> float:
	return gain(original_cost * (1.0 - cfg.scrap_loss))
