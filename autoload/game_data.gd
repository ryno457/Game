extends Node
## Single load point for every `.tres` the sim reads.
##
## Nothing else in the project may `load()` a balance resource. If a system
## needs a number, it asks here — that keeps the "no numbers in .gd files"
## convention enforceable by grep.

const MODULE_DIR := "res://data/modules/"
const UNIT_DIR := "res://data/units/"

var modules: Dictionary = {}      # StringName -> ModuleDef
var units: Dictionary = {}        # StringName -> UnitStats
var waves: WaveTable
var adaptation: AdaptationRules
var terrain: TerrainConfig
var chassis: ChassisConfig


func _ready() -> void:
	modules = _load_dir(MODULE_DIR)
	units = _load_dir(UNIT_DIR)
	waves = load("res://data/waves/biodome_01.tres")
	adaptation = load("res://data/adaptation/default_rules.tres")
	terrain = load("res://data/terrain/biodome_01.tres")
	chassis = load("res://data/chassis/sentinel.tres")


func _load_dir(path: String) -> Dictionary:
	var out := {}
	for file in DirAccess.get_files_at(path):
		if not file.ends_with(".tres"):
			continue
		var res: Resource = load(path + file)
		out[res.id] = res
	return out
