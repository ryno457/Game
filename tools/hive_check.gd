extends SceneTree
## Do the four triggers fire when they should, and STOP when they should?
##
##   godot --headless --path . --script tools/hive_check.gd
##
## The off switch is the part worth testing. A trigger that fires is easy; a
## trigger that keeps firing after the player has answered it is a timer in a
## costume, and every one of these has an answer: free the debris, kill the
## plant, kill the creature, survive the one group a patch holds.
##
## No renderer, no scene. Hive and WaveDirector are RefCounted precisely so
## that the rules can be driven from here.

const MAP := "res://data/terrain/biodome_map_01.tres"
const HIVE := "res://data/gameplay/hive.tres"
const WAVES := "res://data/waves/biodome_01.tres"
const PROTO := "res://data/gameplay/proto.tres"

var _failed := 0
var _field: Heightfield
var _cfg: HiveConfig
## uid -> hp, standing in for the scene's alien array.
var _hp: Dictionary = {}
var _pos: Dictionary = {}
var _next := 1
var _broods: Array = []


func _initialize() -> void:
	print("SENTINEL — hive triggers\n")
	var map: TerrainMap = load(MAP)
	_field = TerrainBuilder.build(map)
	_cfg = load(HIVE)

	_placement()
	_plants()
	_patches()
	_roamers()
	_debris_wave()

	print("")
	if _failed == 0:
		print("HIVE: OK")
	else:
		print("%d CHECK(S) FAILED" % _failed)
	quit(_failed)


func _ok(name: String, cond: bool, detail: String) -> void:
	if not cond:
		_failed += 1
	print("  %s  %s  %s" % ["PASS" if cond else "FAIL", name.rpad(44), detail])


func _hive() -> Hive:
	var h := Hive.new(_cfg, _field, 4242)
	h.brood_due.connect(func(at, n, src): _broods.append(
		{"at": at, "n": n, "src": src}))
	_hp.clear()
	_pos.clear()
	_broods.clear()
	_next = 1
	return h


func _spawn(at: Vector2, hp: float) -> int:
	var uid := _next
	_next += 1
	_hp[uid] = hp
	_pos[uid] = at
	return uid


func _alive(uid: int) -> bool:
	return _hp.has(uid) and float(_hp[uid]) > 0.0


func _at(uid: int) -> Vector2:
	return _pos.get(uid, Vector2.ZERO)


## Every plant the dressing would place, so the test picks nests the same way
## the game does rather than from made-up coordinates.
func _plant_spots() -> Array[Vector2]:
	var plan: BiomeDressing = load("res://data/biomes/biodome_01_dressing.tres")
	var placed := Dressing.place(_field, plan, _field_spawn())
	var out: Array[Vector2] = []
	for t in placed.get(&"flora_brain", []):
		var tr: Transform3D = t
		out.append(Vector2(tr.origin.x, tr.origin.z))
	return out


func _field_spawn() -> Vector2:
	var map: TerrainMap = load(MAP)
	return map.spawn


# --- the map is populated ----------------------------------------------------
func _placement() -> void:
	print("what is on the map")
	var h := _hive()
	var landing := _field_spawn()
	var made := h.place(_plant_spots(), landing, 11.0)

	_ok("two large creatures, and only two", h.roamers.size() == 2,
		"%d roaming" % h.roamers.size())
	# Two is a decision about which way to go; if they start on top of each
	# other it is one landmark with two health bars.
	var apart := 0.0
	if h.roamers.size() == 2:
		apart = (h.roamers[0].home as Vector2).distance_to(h.roamers[1].home)
	_ok("and they are not in the same place", apart > _cfg.roamer_wander_m * 2.0,
		"%.0f m apart, territory is %.0f m" % [apart, _cfg.roamer_wander_m])

	_ok("the plant nests are real plants",
		h.plants.size() == mini(_cfg.plant_nest_count, _plant_spots().size()),
		"%d nests from %d plants" % [h.plants.size(), _plant_spots().size()])

	_ok("there are buried patches", h.patches.size() >= _cfg.patch_count / 2,
		"%d of %d asked for" % [h.patches.size(), _cfg.patch_count])
	# One step must not trip three of them.
	var closest := 1.0e9
	for i in h.patches.size():
		for j in range(i + 1, h.patches.size()):
			closest = minf(closest,
				(h.patches[i].pos as Vector2).distance_to(h.patches[j].pos))
	_ok("no two patches share a footstep", closest >= _cfg.patch_spacing_m,
		"closest pair %.1f m, minimum %.1f" % [closest, _cfg.patch_spacing_m])

	# Nothing may be waiting on top of where the player lands.
	var near := 0
	for q in h.patches:
		if (q.pos as Vector2).distance_to(landing) < 11.0 * 2.0:
			near += 1
	for p in h.plants:
		if (p.pos as Vector2).distance_to(landing) < 11.0 * 2.0:
			near += 1
	_ok("the landing site is clear", near == 0, "%d sources within 22 m" % near)
	_ok("place() reports what it made",
		(made.roamers as Array).size() == h.roamers.size()
			and (made.plants as Array).size() == h.plants.size(), "")


# --- 2. the plants -----------------------------------------------------------
func _plants() -> void:
	print("\n2. a plant wakes when you go near, and stops when it dies")
	var h := _hive()
	h.place(_plant_spots(), _field_spawn(), 11.0)
	if h.plants.is_empty():
		_ok("there is a plant to test", false, "none placed")
		return
	var at: Vector2 = h.plants[0].pos
	h.bind_plant(0, _spawn(at, _cfg.plant_hp))

	# Far away: nothing happens, however long you wait.
	for i in 200:
		h.tick(0.1, at + Vector2(_cfg.plant_notice_m * 3.0, 0.0), _alive, _at)
	_ok("it ignores you from across the map", _broods.is_empty(),
		"%d broods in 20 s at %.0f m" % [_broods.size(), _cfg.plant_notice_m * 3.0])

	# Walk in: it wakes and keeps calling.
	for i in 200:
		h.tick(0.1, at, _alive, _at)
	var woke_count := _broods.size()
	_ok("walking up to it wakes it", woke_count >= 2,
		"%d broods in 20 s" % woke_count)

	# Walking away does NOT stop it. Only killing it does.
	_broods.clear()
	for i in 200:
		h.tick(0.1, at + Vector2(_cfg.plant_notice_m * 3.0, 0.0), _alive, _at)
	_ok("backing off does not stop it", _broods.size() >= 2,
		"%d broods after retreating" % _broods.size())

	# Kill it.
	_hp[int(h.plants[0].alien)] = 0.0
	_broods.clear()
	for i in 400:
		h.tick(0.1, at, _alive, _at)
	_ok("killing it stops it, permanently", _broods.is_empty(),
		"%d broods in 40 s standing on the corpse" % _broods.size())


# --- 3. the buried patches ---------------------------------------------------
func _patches() -> void:
	print("\n3. a patch gives one group and is then spent")
	var h := _hive()
	h.place(_plant_spots(), _field_spawn(), 11.0)
	if h.patches.is_empty():
		_ok("there is a patch to test", false, "none placed")
		return
	var at: Vector2 = h.patches[0].pos

	h.tick(0.1, at + Vector2(_cfg.patch_notice_m * 2.0, 0.0), _alive, _at)
	_ok("it does nothing until you stand on it", _broods.is_empty(), "")

	h.tick(0.1, at, _alive, _at)
	_ok("stepping on it opens it", _broods.size() == 1,
		"%d group" % _broods.size())
	var n: int = _broods[0].n if _broods.size() > 0 else 0
	_ok("three or four come up",
		n >= _cfg.patch_count_min and n <= _cfg.patch_count_max,
		"%d, range is %d-%d" % [n, _cfg.patch_count_min, _cfg.patch_count_max])

	_broods.clear()
	for i in 600:
		h.tick(0.1, at, _alive, _at)
	_ok("and it is spent — standing there does nothing", _broods.is_empty(),
		"%d further groups in 60 s" % _broods.size())


# --- 4. the roaming creatures ------------------------------------------------
func _roamers() -> void:
	print("\n4. a creature calls escorts, and killing it stops them")
	var h := _hive()
	var made := h.place(_plant_spots(), _field_spawn(), 11.0)
	if h.roamers.is_empty():
		_ok("there is a creature to test", false, "none placed")
		return
	var at: Vector2 = made.roamers[0]
	var uid := _spawn(at, _cfg.roamer_hp)
	h.bind_roamer(0, uid)

	for i in 300:
		h.tick(0.1, at + Vector2(_cfg.roamer_notice_m * 2.0, 0.0), _alive, _at)
	_ok("it ignores you from outside its ground", _broods.is_empty(),
		"%d broods in 30 s at %.0f m" % [_broods.size(),
			_cfg.roamer_notice_m * 2.0])

	for i in 300:
		h.tick(0.1, at, _alive, _at)
	_ok("getting close brings escorts", _broods.size() >= 2,
		"%d broods in 30 s" % _broods.size())
	var every: float = 30.0 / maxf(1.0, float(_broods.size()))
	_ok("at about the interval it promises",
		absf(every - _cfg.roamer_brood_interval_s) < _cfg.roamer_brood_interval_s * 0.5,
		"one every %.1f s, configured %.1f" % [every, _cfg.roamer_brood_interval_s])

	_hp[uid] = 0.0
	_broods.clear()
	for i in 600:
		h.tick(0.1, at, _alive, _at)
	_ok("killing it stops the escorts", _broods.is_empty(),
		"%d broods in 60 s after it died" % _broods.size())

	# And it stays on its own ground.
	var far := 0.0
	var pos := at
	for i in 2000:
		var goal := h.roamer_goal(0, pos)
		pos = pos.move_toward(goal, 0.1)
		far = maxf(far, pos.distance_to(at))
	_ok("it stays in its territory", far <= _cfg.roamer_wander_m * 1.35,
		"wandered %.0f m, territory is %.0f" % [far, _cfg.roamer_wander_m])


# --- 1. the debris dig -------------------------------------------------------
func _debris_wave() -> void:
	print("\n1. digging debris wakes them, freeing it stops them")
	var table: WaveTable = load(WAVES)
	var w := WaveDirector.new(table)
	# A one-element Array, not an int. GDScript lambdas capture by VALUE, so a
	# captured `var spawns := 0` is a COPY the lambda increments and the test
	# never sees — which is how this check first passed three times over while
	# counting nothing at all. An Array is captured by reference.
	var spawns := [0]
	w.spawn_due.connect(func(_n, _i): spawns[0] += 1)

	# Windows are in INTERVALS, not in seconds. Written as "30 s" this check
	# read as a failure when it was really asking for two groups inside two
	# thirds of one interval.
	var quiet: int = int(table.interval_s * 2.5 / 0.1)
	for i in quiet:
		w.tick(0.1)
	_ok("nothing happens while nobody digs", spawns[0] == 0,
		"%d groups in %.0f s" % [spawns[0], table.interval_s * 2.5])

	w.begin(&"debris_0", 1.0)
	# The first group must arrive while the dig is still running, or trigger 1
	# is decorative: the fight would begin after the prize was already won.
	var dig: int = int(load(PROTO).large_free_s / 0.1)
	for i in dig:
		w.tick(0.1)
	_ok("the first group lands before the dig finishes", spawns[0] >= 1,
		"%d groups in the %.0f s a large piece takes"
			% [spawns[0], load(PROTO).large_free_s])

	for i in int(table.interval_s * 1.5 / 0.1):
		w.tick(0.1)
	_ok("digging keeps bringing them", spawns[0] >= 2,
		"%d groups in %.0f s, one interval is %.0f"
			% [spawns[0], load(PROTO).large_free_s + table.interval_s * 1.5,
				table.interval_s])

	var during: int = spawns[0]
	w.end()
	for i in int(table.interval_s * 3.0 / 0.1):
		w.tick(0.1)
	_ok("freeing the piece stops them", spawns[0] == during,
		"%d more groups in %.0f s after it came free"
			% [spawns[0] - during, table.interval_s * 3.0])
