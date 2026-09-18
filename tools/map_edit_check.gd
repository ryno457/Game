extends SceneTree
## Does an edited map survive the round trip, and does a bad one get refused?
##
##   godot --headless --path . --script tools/map_edit_check.gd
##
## The editor itself needs a finger and a screen. What can be tested without
## either is the part that would silently lose someone's afternoon: the data
## model, the JSON round trip, undo, and the validation that stands between a
## pasted file and the repository's resources.

const MAP := "res://data/terrain/biodome_map_01.tres"
const TMP := "user://map_edit_check.json"

var _failed := 0
var _w := 0.0
var _h := 0.0
var _cfg: TerrainConfig


func _initialize() -> void:
	print("SENTINEL — map edits\n")
	var map: TerrainMap = load(MAP)
	_cfg = map.terrain
	_w = _cfg.cells_x * _cfg.cell_size_m
	_h = _cfg.cells_z * _cfg.cell_size_m

	_editing()
	_undo()
	_round_trip()
	_refusing()
	_shape()
	_placements()

	print("")
	if _failed == 0:
		print("MAP EDITS: OK")
	else:
		print("%d CHECK(S) FAILED" % _failed)
	quit(_failed)


func _ok(name: String, cond: bool, detail: String) -> void:
	if not cond:
		_failed += 1
	print("  %s  %s  %s" % ["PASS" if cond else "FAIL", name.rpad(46), detail])


func _sample() -> MapEdit:
	var e := MapEdit.new()
	e.notes = "a test map"
	e.add(&"ops", {"op": "crater", "x": 40.0, "z": 40.0, "r": 6.0,
		"amount": 0.05})
	e.add(&"ops", {"op": "plateau", "x": 60.0, "z": 50.0, "r": 12.0,
		"level": 0.62, "strength": 1.0})
	e.add(&"blocked", {"x": 90.0, "z": 70.0, "r": 8.0})
	e.add(&"plants", {"model": "flora_brain", "x": 30.0, "z": 60.0,
		"yaw": 1.0, "scale": 1.1})
	e.add(&"roamers", {"x": 25.0, "z": 25.0, "wander_m": 22.0})
	e.add(&"nests", {"x": 100.0, "z": 40.0, "count": 4, "interval_s": 7.0})
	e.add(&"patches", {"x": 70.0, "z": 90.0, "count": 3})
	return e


# --- editing -----------------------------------------------------------------
func _editing() -> void:
	print("what an edit holds")
	var e := _sample()
	_ok("everything goes in its own list", e.ops.size() == 2
			and e.blocked.size() == 1 and e.plants.size() == 1
			and e.roamers.size() == 1 and e.nests.size() == 1
			and e.patches.size() == 1, e.summary())
	# One door in, so nothing can be added without becoming undoable.
	_ok("and every one of them is undoable", e.count() == 7,
		"%d edits recorded" % e.count())
	_ok("a clean edit has nothing to complain about",
		e.problems(_w, _h).is_empty(), "")


# --- undo --------------------------------------------------------------------
func _undo() -> void:
	print("\nundo takes back the LAST thing, whatever kind it was")
	var e := _sample()
	var gone := e.undo()
	_ok("the last edit was a patch, so a patch came back",
		e.patches.is_empty() and int(gone.get("count", 0)) == 3,
		"%d patches left" % e.patches.size())
	e.undo()
	_ok("then the nest", e.nests.is_empty(), "%d nests left" % e.nests.size())
	# Order matters: undo is not "remove from the biggest list".
	e.undo()
	_ok("then the roamer, not one of the two ops",
		e.roamers.is_empty() and e.ops.size() == 2,
		"%d roaming, %d ops" % [e.roamers.size(), e.ops.size()])
	for i in 10:
		e.undo()
	_ok("undoing past the beginning is not an error", e.is_empty(),
		"%d edits left after ten extra undos" % e.count())
	_ok("and it says so rather than pretending", e.undo().is_empty(), "")


# --- the round trip ----------------------------------------------------------
func _round_trip() -> void:
	print("\nit survives being written out and read back")
	var e := _sample()
	var err := e.save_to(TMP)
	_ok("it writes", err == "", err if err != "" else TMP)

	var back := MapEdit.new()
	var read := back.load_from(TMP)
	_ok("it reads", read == "", read if read != "" else "")
	_ok("with everything still in it", back.summary() == e.summary(),
		back.summary())
	_ok("and the notes", back.notes == e.notes, "'%s'" % back.notes)
	# The numbers matter more than the counts: a JSON round trip that turned
	# 0.62 into 0 would still pass every count check above.
	_ok("and the numbers are the same numbers",
		is_equal_approx(float(back.ops[1].level), 0.62)
			and is_equal_approx(float(back.blocked[0].r), 8.0)
			and int(back.nests[0].count) == 4,
		"level %.2f, radius %.0f, count %d" % [float(back.ops[1].level),
			float(back.blocked[0].r), int(back.nests[0].count)])
	# And it is still editable, not just readable.
	back.undo()
	_ok("and a file that was read back is still undoable",
		back.patches.is_empty(), "%d patches after one undo"
			% back.patches.size())


# --- refusing bad input ------------------------------------------------------
func _refusing() -> void:
	print("\nand a bad file is refused, with a reason")
	var e := MapEdit.new()
	_ok("something that is not JSON",
		e.from_json("this is not json at all") != "", "")
	_ok("JSON that is not a map edit",
		e.from_json('{"hello": "world"}') != "", "")
	_ok("a file from a newer editor",
		e.from_json('{"format": "%s", "version": 99}' % MapEdit.FORMAT) != "",
		"")

	var off := MapEdit.new()
	off.add(&"nests", {"x": _w + 40.0, "z": 10.0, "count": 2})
	var probs := off.problems(_w, _h)
	_ok("a placement off the edge of the map", probs.size() == 1,
		probs[0] if probs.size() > 0 else "no complaint")

	var empty := MapEdit.new()
	empty.add(&"patches", {"x": 20.0, "z": 20.0, "count": 0})
	_ok("a patch that spawns nothing",
		not empty.problems(_w, _h).is_empty(),
		empty.problems(_w, _h)[0] if not empty.problems(_w, _h).is_empty()
			else "no complaint")

	var noradius := MapEdit.new()
	noradius.add(&"blocked", {"x": 20.0, "z": 20.0, "r": 0.0})
	_ok("a blocked area with no radius",
		not noradius.problems(_w, _h).is_empty(), "")


# --- it actually changes the ground ------------------------------------------
func _shape() -> void:
	print("\nthe edits really move the terrain")
	var e := MapEdit.new()
	var at := Vector2(_w * 0.5, _h * 0.5)
	var field := TerrainBuilder.build(load(MAP))
	var before := field.height_at(at)

	e.add(&"ops", {"op": "plateau", "x": at.x, "z": at.y, "r": 10.0,
		"level": minf(0.95, before + 0.25), "strength": 1.0})
	for op in e.all_ops(_impassable()):
		TerrainBuilder.apply_op(field, op)
	_ok("raising a plateau raises the ground",
		field.height_at(at) > before + 0.1,
		"%.3f -> %.3f" % [before, field.height_at(at)])

	# The one that matters for "where the player cannot go": it has to actually
	# cross the impassable threshold, not just dip. CLAUDE.md records this
	# exact mistake from the first prototype — an effect that LOOKS like it is
	# happening is not evidence that it is.
	var b := MapEdit.new()
	var spot := Vector2(_w * 0.5 + 24.0, _h * 0.5)
	var f2 := TerrainBuilder.build(load(MAP))
	var was_passable := f2.is_passable(spot)
	b.add(&"blocked", {"x": spot.x, "z": spot.y, "r": 9.0})
	for op in b.all_ops(_impassable()):
		TerrainBuilder.apply_op(f2, op)
	_ok("a blocked area is genuinely impassable, not just a dent",
		was_passable and not f2.is_passable(spot),
		"passable %s -> %s, height %.3f against a threshold of %.2f"
			% [was_passable, f2.is_passable(spot), f2.height_at(spot),
				_cfg.impassable_below])
	# And its rim, not only its middle.
	_ok("including most of the way out to its rim",
		not f2.is_passable(spot + Vector2(6.0, 0.0)),
		"6 m from the centre of a 9 m disc")

	# Blocked LAST: an area marked off-limits stays off-limits whatever else
	# the designer did there.
	var c := MapEdit.new()
	c.add(&"blocked", {"x": spot.x, "z": spot.y, "r": 9.0})
	c.add(&"ops", {"op": "plateau", "x": spot.x, "z": spot.y, "r": 9.0,
		"level": 0.7, "strength": 1.0})
	var f3 := TerrainBuilder.build(load(MAP))
	for op in c.all_ops(_impassable()):
		TerrainBuilder.apply_op(f3, op)
	_ok("and a blocked area beats a plateau drawn over it",
		not f3.is_passable(spot),
		"height %.3f" % f3.height_at(spot))


func _impassable() -> float:
	return maxf(0.0, _cfg.impassable_below - 0.05)


# --- the hive reads the placements -------------------------------------------
func _placements() -> void:
	print("\nthe hive uses hand placements, and scatters the rest")
	var field := TerrainBuilder.build(load(MAP))
	var cfg: HiveConfig = load("res://data/gameplay/hive.tres")

	var pl := HivePlacements.new()
	pl.roamers.append(Vector2(30.0, 30.0))
	pl.roamers.append(Vector2(110.0, 80.0))
	pl.roamers.append(Vector2(70.0, 20.0))
	pl.patches.append(Vector2(50.0, 50.0))
	pl.patch_counts.append(9)

	var h := Hive.new(cfg, field, 4242)
	h.placed = pl
	h.place([], Vector2(75.0, 56.0), 11.0)
	_ok("it places exactly the creatures it was given",
		h.roamers.size() == 3, "%d roaming, config asks for %d"
			% [h.roamers.size(), cfg.roamer_count])
	_ok("where it was told to, not somewhere better",
		(h.roamers[0].home as Vector2).distance_to(Vector2(30.0, 30.0)) < 0.01,
		"first one at %s" % str(h.roamers[0].home))
	_ok("the named patch is there, and the rest are scattered",
		h.patches.size() >= cfg.patch_count
			and (h.patches[0].pos as Vector2).distance_to(Vector2(50.0, 50.0))
				< 0.01,
		"%d patches, first at %s" % [h.patches.size(), str(h.patches[0].pos)])

	# The count the designer typed is the count that comes up.
	var broods: Array = []
	h.brood_due.connect(func(at, n, src): broods.append({"n": n, "src": src}))
	h.tick(0.1, Vector2(50.0, 50.0), func(_u): return true,
		func(_u): return Vector2.ZERO)
	_ok("and it spawns the number that was typed, not a rolled one",
		broods.size() == 1 and int(broods[0].n) == 9,
		"%d came up, 9 was asked for" % (int(broods[0].n)
			if broods.size() > 0 else -1))

	# Nothing placed behaves exactly as it did before the feature existed.
	var bare := Hive.new(cfg, field, 4242)
	bare.placed = HivePlacements.new()
	bare.place([], Vector2(75.0, 56.0), 11.0)
	var none := Hive.new(cfg, field, 4242)
	none.place([], Vector2(75.0, 56.0), 11.0)
	_ok("an EMPTY placements resource changes nothing at all",
		bare.roamers.size() == none.roamers.size()
			and bare.patches.size() == none.patches.size(),
		"%d/%d roaming, %d/%d patches" % [bare.roamers.size(),
			none.roamers.size(), bare.patches.size(), none.patches.size()])
