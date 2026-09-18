class_name HivePlacements
extends Resource
## Where the hand-placed things on ONE map go.
##
## Separate from HiveConfig on purpose. HiveConfig is RULES — how far a creature
## wanders, how long a nest waits between broods, how many come up out of a
## patch — and those rules should hold in biodome 2 without editing. This is one
## map's LAYOUT, and none of it transfers. Mixing the two would mean a second
## biodome could not reuse the first one's balance.
##
## Written by tools/apply_map_edit.gd from a JSON the map editor produced. Read
## by Hive.place(), which falls back to its own scatter for anything this does
## not specify — an empty resource behaves exactly like no resource at all,
## which is what keeps the procedural map working while this is half filled in.
##
## PARALLEL ARRAYS, which is not the shape anyone would choose. Godot cannot
## export an Array[Dictionary] through the inspector usefully, and a .tres full
## of dictionaries is unreadable in a diff. Positions and counts are index-
## matched; `nest_count_at` and `patch_count_at` are the only things that should
## read them, so the pairing lives in one place.

@export var display_name: String = ""
## Whatever the designer typed in the editor's notes field.
@export var source_notes: String = ""

@export_group("The two that roam")
@export var roamers: Array[Vector2] = []

@export_group("Plant nests")
@export var nests: Array[Vector2] = []
## How many come out of each, index-matched to `nests`.
@export var nest_counts: Array[int] = []

@export_group("Burrow patches")
@export var patches: Array[Vector2] = []
@export var patch_counts: Array[int] = []

@export_group("Hand-placed vegetation")
## (x, yaw, z) — Vector3 rather than a position and a separate angle, because
## two index-matched arrays are already one too many.
@export var plants: Array[Vector3] = []
@export var plant_models: Array[String] = []
@export var plant_scales: Array[float] = []


func is_empty() -> bool:
	return roamers.is_empty() and nests.is_empty() and patches.is_empty() \
		and plants.is_empty()


## Count for nest `i`, or `fallback` if the editor did not say. Out-of-range is
## not an error: the arrays are edited by hand often enough that a short
## counts list is a likely state, and the rule's own default is a fine answer.
func nest_count_at(i: int, fallback: int) -> int:
	return nest_counts[i] if i >= 0 and i < nest_counts.size() else fallback


func patch_count_at(i: int, fallback: int) -> int:
	return patch_counts[i] if i >= 0 and i < patch_counts.size() else fallback


func plant_model_at(i: int) -> String:
	return plant_models[i] if i >= 0 and i < plant_models.size() else ""


func plant_scale_at(i: int) -> float:
	return plant_scales[i] if i >= 0 and i < plant_scales.size() else 1.0
