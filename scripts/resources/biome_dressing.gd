class_name BiomeDressing
extends Resource
## Everything growing on a biodome's floor, as a seed plus rules.

@export var display_name: String = ""
@export var seed: int = 20260915
## Nothing is placed within this of the landing site. The player's first minute
## should not open with an arch dropped on their module.
@export var landing_clear_m: float = 12.0
@export var entries: Array[PropScatter] = []


func total_props() -> int:
	var n := 0
	for e in entries:
		n += e.count
	return n
