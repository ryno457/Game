extends SceneTree
## Take a map edited on the phone and write it into the game's resources.
##
##   godot --headless --path . --script tools/apply_map_edit.gd -- [file.json]
##   godot --headless --path . --script tools/apply_map_edit.gd -- file.json --dry
##
## Defaults to data/maps/map_edit.json, which is where a JSON pasted into the
## repository should go.
##
## IT VALIDATES EVERYTHING BEFORE IT WRITES ANYTHING. The input is a file that
## has been through a phone, a clipboard and possibly a chat window, and a
## half-applied map — new terrain, old hive — is worse than a rejected one. If
## any entry is off the map or missing a field, nothing is touched and the
## reasons are printed.
##
## WHAT IT WRITES
##   data/terrain/biodome_map_01.tres   the terrain ops, appended to the map's
##                                      own, with the blocked discs last
##   data/gameplay/hive.tres            counts and spacing the placements imply
##   data/gameplay/hive_placements.tres hand-placed roamers, nests and patches
##   data/biomes/*_handplaced.tres      hand-placed vegetation
##
## The originals are copied to <name>.bak first, once per run, so a bad apply
## is one `git checkout` or one rename away from undone.

const MAP := "res://data/terrain/biodome_map_01.tres"
const HIVE := "res://data/gameplay/hive.tres"
const PLACEMENTS := "res://data/gameplay/hive_placements.tres"
const DEFAULT_IN := "res://data/maps/map_edit.json"

var _failed := 0


func _initialize() -> void:
	var argv := OS.get_cmdline_user_args()
	var path := DEFAULT_IN
	var dry := false
	for a in argv:
		var s := String(a)
		if s == "--dry":
			dry = true
		elif s != "":
			path = s if s.begins_with("res://") or s.begins_with("/") \
				else "res://" + s

	print("SENTINEL — apply a map edit\n")
	print("  reading  %s" % path)

	var edit := MapEdit.new()
	var err := edit.load_from(path)
	if err != "":
		_die(err)
		return

	var map: TerrainMap = load(MAP)
	if map == null:
		_die("cannot load %s" % MAP)
		return
	var cfg: TerrainConfig = map.terrain
	var w: float = cfg.cells_x * cfg.cell_size_m
	var h: float = cfg.cells_z * cfg.cell_size_m

	if edit.map_path != MAP:
		print("  NOTE     this edit says it is for %s" % edit.map_path)

	var problems := edit.problems(w, h)
	if not problems.is_empty():
		print("\n  %d problem(s) — NOTHING has been written:" % problems.size())
		for p in problems:
			print("    - %s" % p)
		_die("fix those and run it again")
		return

	print("  contents %s" % edit.summary())
	if edit.notes != "":
		print("  notes    %s" % edit.notes)

	# A sanity check that is worth more than all the field validation: does the
	# edited terrain still have ground the player can stand on? A slider left
	# at the wrong end can flatten a biodome to a chasm, and every individual
	# entry in that file would be perfectly valid.
	var before := _walkable(TerrainBuilder.build(map), cfg)
	var after_field := TerrainBuilder.build(map)
	for op in edit.all_ops(maxf(0.0, cfg.impassable_below - 0.05)):
		TerrainBuilder.apply_op(after_field, op)
	var after := _walkable(after_field, cfg)
	print("  walkable %.1f%% before, %.1f%% after" % [before * 100.0, after * 100.0])
	if after < 0.04:
		_die("that would leave %.1f%% of the map walkable — refusing" % (after * 100.0))
		return

	if dry:
		print("\n  --dry: nothing written.")
		quit(0)
		return

	_write_map(map, edit, cfg)
	_write_hive(edit)
	_write_placements(edit)
	print("\nAPPLIED. Run tools/proto_drive.gd and take a screenshot before "
		+ "trusting it.")
	quit(0)


## Fraction of cells a unit could stand on.
func _walkable(hf: Heightfield, cfg: TerrainConfig) -> float:
	var n := 0
	var total := cfg.cells_x * cfg.cells_z
	for i in total:
		if hf.heights[i] >= cfg.impassable_below:
			n += 1
	return float(n) / maxf(1.0, float(total))


func _write_map(map: TerrainMap, edit: MapEdit, cfg: TerrainConfig) -> void:
	_backup(MAP)
	var ops := map.ops.duplicate(true)
	for op in edit.all_ops(maxf(0.0, cfg.impassable_below - 0.05)):
		ops.append(op)
	map.ops.assign(ops)
	var e := ResourceSaver.save(map, MAP)
	print("  wrote    %s  (+%d ops, %d total)  %s"
		% [MAP, edit.ops.size() + edit.blocked.size(), ops.size(),
			"ok" if e == OK else error_string(e)])


## The counts the placements imply, written back into HiveConfig.
##
## ONLY THE COUNTS. The editor places specific roamers and nests, and where
## they are is placement data, not configuration — that goes in its own
## resource. What HiveConfig learns from an edit is how MANY of each there are
## and how big a group a patch gives, because the Hive still owns the rules.
func _write_hive(edit: MapEdit) -> void:
	var hive: HiveConfig = load(HIVE)
	if hive == null:
		print("  skipped  %s (cannot load)" % HIVE)
		return
	if edit.roamers.is_empty() and edit.nests.is_empty() \
			and edit.patches.is_empty():
		print("  skipped  %s (the edit places no aliens)" % HIVE)
		return
	_backup(HIVE)
	if not edit.roamers.is_empty():
		hive.roamer_count = edit.roamers.size()
		var widest := 0.0
		for r in edit.roamers:
			widest = maxf(widest, float(r.get("wander_m", hive.roamer_wander_m)))
		hive.roamer_wander_m = widest if widest > 0.0 else hive.roamer_wander_m
	if not edit.nests.is_empty():
		hive.plant_nest_count = edit.nests.size()
		var most := 0
		for n in edit.nests:
			most = maxi(most, int(n.get("count", hive.plant_brood_count)))
		hive.plant_brood_count = clampi(most, 1, 12)
	if not edit.patches.is_empty():
		hive.patch_count = edit.patches.size()
		var lo := 99
		var hi := 0
		for q in edit.patches:
			var c := int(q.get("count", 3))
			lo = mini(lo, c)
			hi = maxi(hi, c)
		hive.patch_count_min = clampi(lo, 1, 12)
		hive.patch_count_max = clampi(maxi(hi, lo), 1, 12)
		# Spacing has to be no wider than the closest pair actually placed, or
		# the Hive would reject a layout the designer drew on purpose.
		var closest := 1.0e9
		for i in edit.patches.size():
			for j in range(i + 1, edit.patches.size()):
				closest = minf(closest, Vector2(edit.patches[i].x,
					edit.patches[i].z).distance_to(
						Vector2(edit.patches[j].x, edit.patches[j].z)))
		if closest < 1.0e9:
			hive.patch_spacing_m = minf(hive.patch_spacing_m, closest)
	var e := ResourceSaver.save(hive, HIVE)
	print("  wrote    %s  (%d roaming, %d nests, %d patches)  %s"
		% [HIVE, hive.roamer_count, hive.plant_nest_count, hive.patch_count,
			"ok" if e == OK else error_string(e)])


## Exact positions, in their own resource.
##
## Separate from HiveConfig because they are a different KIND of thing: the
## config is rules that would hold on any map, and this is one map's layout.
## Mixing them would mean a second biodome could not reuse the rules.
func _write_placements(edit: MapEdit) -> void:
	var pl := HivePlacements.new()
	pl.display_name = "Biodome 01 — hand placed"
	pl.source_notes = edit.notes
	for r in edit.roamers:
		pl.roamers.append(Vector2(float(r.x), float(r.z)))
	for n in edit.nests:
		pl.nests.append(Vector2(float(n.x), float(n.z)))
		pl.nest_counts.append(int(n.get("count", 2)))
	for q in edit.patches:
		pl.patches.append(Vector2(float(q.x), float(q.z)))
		pl.patch_counts.append(int(q.get("count", 3)))
	for p in edit.plants:
		pl.plants.append(Vector3(float(p.x), float(p.get("yaw", 0.0)),
			float(p.z)))
		pl.plant_models.append(String(p.get("model", "")))
		pl.plant_scales.append(float(p.get("scale", 1.0)))
	DirAccess.make_dir_recursive_absolute("res://data/gameplay")
	if FileAccess.file_exists(PLACEMENTS):
		_backup(PLACEMENTS)
	var e := ResourceSaver.save(pl, PLACEMENTS)
	print("  wrote    %s  (%d roaming, %d nests, %d patches, %d plants)  %s"
		% [PLACEMENTS, pl.roamers.size(), pl.nests.size(), pl.patches.size(),
			pl.plants.size(), "ok" if e == OK else error_string(e)])


## One copy of the original, before the first write to it this run.
var _backed_up: Dictionary = {}


func _backup(path: String) -> void:
	if _backed_up.has(path):
		return
	_backed_up[path] = true
	if not FileAccess.file_exists(path):
		return
	var src := FileAccess.open(path, FileAccess.READ)
	if src == null:
		return
	var text := src.get_as_text()
	src.close()
	var dst := FileAccess.open(path + ".bak", FileAccess.WRITE)
	if dst == null:
		return
	dst.store_string(text)
	dst.close()
	print("  backup   %s.bak" % path)


func _die(why: String) -> void:
	print("\nNOT APPLIED: %s" % why)
	quit(1)
