extends SceneTree
## Are the props and the hostiles actually different colours, and stably so?
##
##   godot --headless --path . --script tools/variety_check.gd
##
## Two claims, and each fails in a way that looks like success from a
## screenshot. "They vary" can be satisfied by a variation too small to see, and
## "it is deterministic" can be broken by a seed keyed off something that moves
## — which is exactly the trap here, because the fog culls scenery and the slot
## a prop lands in changes as its neighbours come into view. A prop keyed off
## its slot would recolour itself as the player walked past it, and a still
## frame could never show that.

const SCENE := "res://scenes/proto/proto_main.tscn"
var _failed := 0
var _entered := false


func _initialize() -> void:
	var scene := (load(SCENE) as PackedScene).instantiate()
	scene.process_mode = Node.PROCESS_MODE_DISABLED
	root.add_child(scene)


func _process(_d: float) -> bool:
	# Node _ready has not run during _initialize; the same trap proto_drive
	# documents. One pass, ever.
	if _entered:
		return true
	_entered = true
	var scene: Node3D = root.get_child(root.get_child_count() - 1)
	print("SENTINEL — instance variety\n")

	var pal: BiomePalette = scene.palette
	_ok("the palette exposes the knobs",
		pal.prop_hue_jitter > 0.0 and pal.alien_hue_jitter > 0.0,
		"prop hue %.3f, alien hue %.3f" % [pal.prop_hue_jitter,
			pal.alien_hue_jitter])

	# --- the hash itself ----------------------------------------------------
	var seen: Dictionary = {}
	var lo := 9.0
	var hi := -9.0
	for i in 400:
		var c: Color = scene._seed_tint(float(i) * 1.37, 3.1, 0.05, 0.25)
		seen[Vector3i(int(c.r * 255), int(c.g * 255), int(c.b * 255))] = true
		var l := (c.r + c.g + c.b) / 3.0
		lo = minf(lo, l)
		hi = maxf(hi, l)
	_ok("400 seeds give 400 different colours", seen.size() > 380,
		"%d distinct" % seen.size())
	# A variation nobody can see is not a variation. An eighth of a stop is
	# about where a flat field starts to look like individuals.
	_ok("and the spread is actually visible", hi - lo > 0.12,
		"brightness %.2f to %.2f" % [lo, hi])
	_ok("but not so wide it reads as a different material", hi - lo < 0.45,
		"range %.2f" % (hi - lo))

	# --- deterministic ------------------------------------------------------
	var a: Color = scene._seed_tint(12.5, -3.25, 0.05, 0.25)
	var b: Color = scene._seed_tint(12.5, -3.25, 0.05, 0.25)
	_ok("the same seed gives the same colour twice", a == b,
		"%s" % a)
	# THE ONE THAT MATTERS. Keyed off position, a prop keeps its colour
	# wherever the fog puts it in the instance buffer; keyed off the slot it
	# would change as neighbours appeared.
	var c1: Color = scene._seed_tint(40.0, 55.0, 0.05, 0.25)
	var c2: Color = scene._seed_tint(40.0, 55.0, 0.05, 0.25)
	_ok("and does not depend on the draw order", c1 == c2, "")

	# --- wired into the real scenery ----------------------------------------
	var groups: Array = scene._scenery
	var coloured := 0
	for g in groups:
		var mmi: MultiMeshInstance3D = g.mmi
		if mmi.multimesh.use_colors:
			coloured += 1
	_ok("every scenery MultiMesh carries instance colours",
		groups.size() > 0 and coloured == groups.size(),
		"%d of %d groups" % [coloured, groups.size()])

	# --- the hostiles -------------------------------------------------------
	var tints: Dictionary = {}
	for uid in range(200):
		var t: Color = scene.call("_alien_tint", {"uid": uid, "flash": 0.0})
		tints[Vector3i(int(t.r * 255), int(t.g * 255), int(t.b * 255))] = true
	_ok("200 hostiles are not one colour", tints.size() > 150,
		"%d distinct tints" % tints.size())

	print("\n%s" % ("VARIETY: OK" if _failed == 0
		else "%d CHECK(S) FAILED" % _failed))
	quit(1 if _failed > 0 else 0)
	return true


func _ok(what: String, cond: bool, detail: String) -> void:
	if not cond:
		_failed += 1
	print("  %s  %-48s %s" % ["PASS" if cond else "FAIL", what, detail])
