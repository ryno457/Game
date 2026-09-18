class_name MapEdit
extends RefCounted
## Everything a person can change about a biodome, as plain data.
##
## THE WHOLE THING IS A LIST OF EDITS, in order. That is not a style choice —
## it is the same shape TerrainMap already uses ("a seed plus a list of
## operations", CLAUDE.md risk item 3), which means a sculpted map costs a few
## kilobytes of JSON rather than megabytes of floats, undo is `pop_back`, and
## the apply tool can hand the ops straight to TerrainBuilder without
## translating anything.
##
## Plain RefCounted, like Hive and WaveDirector and for the same reason: the
## rules worth testing are the serialising and the validating, and neither
## needs a renderer. See tools/map_edit_check.gd.
##
## WHAT THE FOUR LISTS MEAN
##
##   ops      terrain shape, in TerrainBuilder's own op vocabulary. A sculpt
##            stroke is a `crater` with a positive or negative amount; a
##            plateau stamp is a `plateau`; extending one is more plateaus.
##   blocked  discs the player may not walk into, carved as a CHASM. The
##            honest answer when the obstacle is the terrain itself. Stored
##            separately from `ops` even though applying one MAKES an op,
##            because the intent is worth keeping: a chasm the designer dug and
##            a chasm that says "not this way" are the same heights and
##            different decisions, and only one should move if the impassable
##            threshold is retuned.
##   walls    free-form outlines nothing may walk into, WITHOUT touching the
##            ground. For a thicket of alien plants or a cluster of structures:
##            those stand on ground that is fine, and digging a hole under them
##            would both say the wrong thing and drop them in it. The props are
##            the visual; the wall is their collision.
##   plants   hand-placed vegetation, on top of whatever the dressing scatters.
##   hive     roamers, plant nests and burrow patches, with their counts.
##
## Coordinates are WORLD METRES throughout, never cells. Cell coordinates are
## the same number today because cell_size_m is 1.0, which is exactly the trap
## that already bit Hive._open_point once.

const FORMAT := "sentinel-map-edit"
const VERSION := 1

## Which map these edits are against. An edit file dropped on the wrong map
## would place everything plausibly and wrongly, so it says.
var map_path := "res://data/terrain/biodome_map_01.tres"
var notes := ""

var ops: Array[Dictionary] = []
var blocked: Array[Dictionary] = []      # {x, z, r}
## Free-form outlines nothing may walk into, WITHOUT changing the ground.
## {points: [Vector2 or [x, z], ...]}
var walls: Array[Dictionary] = []
var plants: Array[Dictionary] = []       # {model, x, z, yaw, scale}
var roamers: Array[Dictionary] = []      # {x, z, wander_m}
var nests: Array[Dictionary] = []        # {x, z, count, interval_s}
var patches: Array[Dictionary] = []      # {x, z, count}

## Every edit in the order it was made, so undo can take the last one off
## whichever list it came from. Entries are [list_name, index].
var _history: Array = []


func is_empty() -> bool:
	return _history.is_empty()


func count() -> int:
	return _history.size()


## Append to a named list and record it for undo. One door in, so nothing can
## be added without becoming undoable — the first version had `ops.append()`
## calls scattered through the editor and half the tools were not undoable.
func add(list_name: StringName, entry: Dictionary) -> void:
	var l := _list(list_name)
	if l == null:
		push_error("MapEdit: no list called '%s'" % list_name)
		return
	l.append(entry)
	_history.append([list_name, l.size() - 1])


## Take back the last edit, whatever kind it was. Returns what it removed, or
## an empty Dictionary if there was nothing to take back.
func undo() -> Dictionary:
	if _history.is_empty():
		return {}
	var last: Array = _history.pop_back()
	var l := _list(last[0])
	if l == null or int(last[1]) >= l.size():
		return {}
	var gone: Dictionary = l[int(last[1])]
	l.remove_at(int(last[1]))
	# Anything recorded AFTER this one that pointed further up the same list
	# has just shifted down by one. There is nothing after it in _history by
	# definition — it was the last entry — but a future redo would need this,
	# and leaving stale indices in a structure is how a subtle bug gets in.
	for h in _history:
		if h[0] == last[0] and int(h[1]) > int(last[1]):
			h[1] = int(h[1]) - 1
	return gone


func clear() -> void:
	ops.clear()
	blocked.clear()
	walls.clear()
	plants.clear()
	roamers.clear()
	nests.clear()
	patches.clear()
	_history.clear()


func _list(name: StringName) -> Array:
	match name:
		&"ops": return ops
		&"blocked": return blocked
		&"walls": return walls
		&"plants": return plants
		&"roamers": return roamers
		&"nests": return nests
		&"patches": return patches
	return []


## The op a blocked disc turns into.
##
## A blocked area IS a chasm, because that is how this game already defines
## impassable ground: below TerrainConfig.impassable_below you cannot walk. It
## is not an invisible wall — the hole is visible, and the ravine edges already
## read that way. `level` comes from the caller so the threshold lives in one
## place; a number typed here would drift the day it is retuned.
##
## A POLYGON, NOT A PLATEAU, and this is the whole reason this function exists
## rather than the editor writing the op inline. A `plateau` op is a disc with
## a cosine-squared falloff: at two thirds of the radius it has moved the
## ground only a QUARTER of the way to the level it was given. A nine-metre
## blocked disc therefore blocked about five metres of ground and left a
## walkable ring the designer drew and cannot see. That is precisely the
## mistake CLAUDE.md records from the first prototype — an effect that looks
## like it is happening is not evidence that it is — and the check for it
## asserts against `is_passable` at the rim, not against the height in the
## middle. `_polygon` fills its interior at full strength and fades only
## outside, which is what "you cannot walk here" needs.
##
## CELLS, NOT METRES. The polygon and plateau ops index the heightfield
## directly, while crater and trench go through `Heightfield.deform`, which
## takes world metres. The two are the same number only because cell_size_m is
## 1.0 today. Nothing here can fix that; it is written down so that whoever
## changes cell_size_m knows to come looking.
const BLOCK_SIDES := 20
## How far outside the circle the ground fades back up. Small: the point is a
## hard edge, and a wide shoulder eats the ground around it.
const BLOCK_EDGE_M := 1.5


static func blocked_op(b: Dictionary, level: float) -> Dictionary:
	var c := Vector2(float(b.x), float(b.z))
	var r: float = maxf(0.5, float(b.r))
	var pts: Array = []
	for i in BLOCK_SIDES:
		var a := TAU * float(i) / float(BLOCK_SIDES)
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	return {"op": "polygon", "points": pts, "level": level,
		"edge": BLOCK_EDGE_M, "strength": 1.0}


## Terrain ops plus the ops the blocked discs imply, in that order.
##
## Blocked LAST on purpose. A designer who carves a hole and then raises a
## plateau over it means the plateau; a designer who marks an area off-limits
## means it stays off-limits whatever else is going on there.
func all_ops(impassable_level: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for o in ops:
		out.append(o)
	for b in blocked:
		out.append(blocked_op(b, impassable_level))
	# Walls last, and it does not matter that they are: they touch no heights,
	# so nothing later can undo one. That is the whole advantage of them being
	# a separate mask rather than a very deep hole.
	for w in walls:
		out.append(wall_op(w))
	return out


## The op a free-form outline turns into, with its corners normalised to real
## Vector2s whatever shape they were stored in. The editor collects them in the
## same cell-space the polygon ops already use.
static func wall_op(w: Dictionary) -> Dictionary:
	return {"op": "wall", "points": wall_points(w)}


## A wall's outline as real Vector2s, whatever shape it arrived in.
##
## JSON HAS NO Vector2. A wall written by the editor holds them; the same wall
## read back from a file holds [x, z] arrays, and a hand-written one holds
## {"x":, "z":} objects because that is what somebody copying the rest of this
## format would write. All three have to work, and the first version only
## handled the one the editor happened to produce — so a saved wall silently
## blocked nothing at all after a round trip.
static func wall_points(w: Dictionary) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in w.get("points", []):
		if p is Vector2:
			out.append(p)
		elif p is Array and (p as Array).size() >= 2:
			out.append(Vector2(float(p[0]), float(p[1])))
		elif p is Dictionary and (p as Dictionary).has("x"):
			out.append(Vector2(float(p["x"]), float(p.get("z", p.get("y", 0.0)))))
	return out


## Twice the signed area of a polygon — the shoelace sum. Sign says winding,
## which nothing here cares about, so callers take the absolute value.
static func _area(pts: PackedVector2Array) -> float:
	var a := 0.0
	for i in pts.size():
		var p := pts[i]
		var q := pts[(i + 1) % pts.size()]
		a += p.x * q.y - q.x * p.y
	return a * 0.5


func to_dict() -> Dictionary:
	return {
		"format": FORMAT, "version": VERSION,
		"map": map_path, "notes": notes,
		"ops": ops, "blocked": blocked, "walls": _walls_as_json(),
		"plants": plants,
		"hive": {"roamers": roamers, "nests": nests, "patches": patches},
	}


## JSON HAS NO Vector2. JSON.stringify turns one into the STRING "(12, 34)",
## which parses back as a string, which `wall_points` cannot read — so a wall
## survived a save and reload as a valid-looking entry that blocked nothing at
## all. Corners go out as [x, z] pairs.
func _walls_as_json() -> Array:
	var out: Array = []
	for w in walls:
		var pts: Array = []
		for p in wall_points(w):
			pts.append([p.x, p.y])
		out.append({"points": pts})
	return out


func to_json() -> String:
	return JSON.stringify(to_dict(), "  ")


## Read a file back. Returns "" on success, or a sentence saying what is wrong.
##
## IT REPORTS RATHER THAN CRASHES, because the file may well have been hand
## edited or pasted through a chat window, and "nothing happened" is the worst
## possible answer to a broken paste.
func from_dict(d: Dictionary) -> String:
	if String(d.get("format", "")) != FORMAT:
		return "not a %s file (format is '%s')" % [FORMAT, d.get("format", "")]
	var v := int(d.get("version", 0))
	if v > VERSION:
		return "made by a newer editor (version %d, this reads %d)" % [v, VERSION]
	clear()
	map_path = String(d.get("map", map_path))
	notes = String(d.get("notes", ""))
	var hive: Dictionary = d.get("hive", {})
	var pairs := [
		[&"ops", d.get("ops", [])], [&"blocked", d.get("blocked", [])],
		[&"walls", d.get("walls", [])],
		[&"plants", d.get("plants", [])],
		[&"roamers", hive.get("roamers", [])],
		[&"nests", hive.get("nests", [])],
		[&"patches", hive.get("patches", [])],
	]
	for pair in pairs:
		for e in pair[1]:
			if e is Dictionary:
				add(pair[0], e as Dictionary)
	return ""


func from_json(text: String) -> String:
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null or not (parsed is Dictionary):
		return "that is not JSON, or not a JSON object"
	return from_dict(parsed as Dictionary)


func save_to(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "cannot write %s (%s)" % [path,
			error_string(FileAccess.get_open_error())]
	f.store_string(to_json())
	f.close()
	return ""


func load_from(path: String) -> String:
	if not FileAccess.file_exists(path):
		return "no file at %s" % path
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "cannot read %s" % path
	var text := f.get_as_text()
	f.close()
	return from_json(text)


## What this edit contains, for the editor's own readout and for the apply
## tool's report. One sentence, because it is read on a phone.
func summary() -> String:
	return "%d shape, %d blocked, %d walls, %d plants, %d roaming, %d nests, %d patches" \
		% [ops.size(), blocked.size(), walls.size(), plants.size(),
			roamers.size(), nests.size(), patches.size()]


## Everything wrong with this edit, as sentences. Empty means it will apply
## cleanly. Checked BEFORE anything is written, because a half-applied map is
## worse than a rejected one.
func problems(map_w: float, map_h: float) -> PackedStringArray:
	var out := PackedStringArray()
	# Walls first: they are the only entry whose shape is a list rather than a
	# point, so the per-point loop below cannot say anything useful about one.
	var wi := 0
	for w in walls:
		var pts := wall_points(w)
		var ctx := "walls[%d]" % wi
		wi += 1
		if pts.size() < 3:
			out.append("%s has %d corners; a wall needs at least 3"
				% [ctx, pts.size()])
			continue
		for p in pts:
			if p.x < 0.0 or p.x > map_w or p.y < 0.0 or p.y > map_h:
				out.append("%s has a corner off the map at (%.0f, %.0f)"
					% [ctx, p.x, p.y])
				break
		# A wall with no area blocks nothing, and a designer who drew one and
		# saw nothing happen would reasonably conclude walls do not work.
		if absf(_area(pts)) < 1.0:
			out.append("%s encloses %.1f square metres; it would block nothing"
				% [ctx, absf(_area(pts))])

	var named := {&"ops": ops, &"blocked": blocked, &"plants": plants,
		&"roamers": roamers, &"nests": nests, &"patches": patches}
	for key in named:
		var i := 0
		for e in named[key]:
			var ctx := "%s[%d]" % [key, i]
			i += 1
			if key == &"ops":
				if not e.has("op"):
					out.append("%s has no 'op'" % ctx)
				continue
			for k in ["x", "z"]:
				if not e.has(k):
					out.append("%s has no '%s'" % [ctx, k])
			var x := float(e.get("x", 0.0))
			var z := float(e.get("z", 0.0))
			if x < 0.0 or x > map_w or z < 0.0 or z > map_h:
				out.append("%s is off the map at (%.0f, %.0f); the map is %.0f x %.0f"
					% [ctx, x, z, map_w, map_h])
			if key == &"blocked" and float(e.get("r", 0.0)) <= 0.0:
				out.append("%s has no radius" % ctx)
			if (key == &"nests" or key == &"patches") \
					and int(e.get("count", 0)) <= 0:
				out.append("%s spawns nothing (count is %d)"
					% [ctx, int(e.get("count", 0))])
	return out
