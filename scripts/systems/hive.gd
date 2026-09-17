class_name Hive
extends RefCounted
## The four things that wake the aliens, and the state each one needs.
##
## Plain RefCounted, like WaveDirector, for the same reason: the trigger rules
## are the part worth testing and they do not need a scene to be tested. See
## tools/hive_check.gd, which drives this with no renderer at all.
##
## WHAT THIS DOES NOT OWN. It does not hold the aliens. proto_main keeps one
## flat `aliens` array and everything — targeting, splash, rendering, the
## MultiMesh — indexes into it; a parallel list for roamers would need all of
## that again and would drift from it. So the Hive emits `brood_due` and the
## scene appends, and asks `alive` about the things it is tracking.
##
## THE OFF SWITCHES ARE THE DESIGN. Every source here can be shut off by the
## player: free the debris, kill the plant, kill the creature, or simply
## survive the one group a patch holds. A source that cannot be switched off is
## a timer in a costume, and the brief says a clock is what v1 got wrong.

signal brood_due(at: Vector2, count: int, source: StringName)
## A nest woke up. The scene uses this for the alert line; the Hive does not
## need anyone to answer it.
signal woke(source: StringName, at: Vector2)

var cfg: HiveConfig
var roamers: Array[Dictionary] = []    # {pos, home, goal, alien(uid), brood_cd}
var plants: Array[Dictionary] = []     # {pos, alien(uid), awake, brood_cd}
var patches: Array[Dictionary] = []    # {pos, spent}

var _field: Heightfield
var _rng := RandomNumberGenerator.new()


func _init(hive_cfg: HiveConfig, field: Heightfield, seed: int) -> void:
	cfg = hive_cfg
	_field = field
	_rng.seed = seed


## Place everything. `plant_spots` are the world positions of the map's alien
## plants, straight from the dressing, so a nest is always a thing the player
## can see rather than an invisible box that happens to sit near one.
##
## Returns the positions the caller must turn into alien entries — the Hive
## records the id it is given back through `bind_roamer` / `bind_plant`,
## because the scene owns the array and is the only thing that can say what a
## new entry became.
##
## AN ID, NOT AN INDEX. Dead aliens are removed from the scene's array, which
## shifts every index after them; a roamer holding index 12 would silently
## start asking about somebody else's hit points the first time anything in
## front of it died. Ids are handed out once and never reused.
func place(plant_spots: Array, landing: Vector2, clear_m: float) -> Dictionary:
	var out := {"roamers": [] as Array[Vector2], "plants": [] as Array[Vector2]}
	roamers.clear()
	plants.clear()
	patches.clear()

	# The two that roam: far from the landing site, and far from each other, so
	# the player meets one at a time and meeting it is a decision.
	var tries := 0
	while roamers.size() < cfg.roamer_count and tries < 400:
		tries += 1
		var p := _open_point()
		if p.distance_to(landing) < clear_m * 3.0:
			continue
		var clash := false
		for r in roamers:
			if p.distance_to(r.home as Vector2) < cfg.roamer_wander_m * 2.0:
				clash = true
				break
		if clash:
			continue
		roamers.append({"pos": p, "home": p, "goal": p, "alien": -1,
			"brood_cd": cfg.roamer_brood_interval_s})
		out.roamers.append(p)

	# The plants. Taken from the dressing's own placements, shuffled, skipping
	# any that sit on top of the player's landing site.
	var spots: Array[Vector2] = []
	for s in plant_spots:
		var v: Vector2 = s
		if v.distance_to(landing) > clear_m * 2.0:
			spots.append(v)
	_shuffle(spots)
	for i in mini(cfg.plant_nest_count, spots.size()):
		plants.append({"pos": spots[i], "alien": -1, "awake": false,
			"brood_cd": 0.0})
		out.plants.append(spots[i])

	# The buried patches, spaced so one step cannot trip three of them.
	tries = 0
	while patches.size() < cfg.patch_count and tries < 3000:
		tries += 1
		var p := _open_point()
		if p.distance_to(landing) < clear_m * 2.0:
			continue
		var clash := false
		for q in patches:
			if p.distance_to(q.pos as Vector2) < cfg.patch_spacing_m:
				clash = true
				break
		if not clash:
			patches.append({"pos": p, "spent": false})
	return out


## The scene appended an alien for this roamer or plant and is telling the Hive
## what id it got. Until it does, the Hive has nothing to ask about.
func bind_roamer(i: int, uid: int) -> void:
	if i >= 0 and i < roamers.size():
		roamers[i].alien = uid


func bind_plant(i: int, uid: int) -> void:
	if i >= 0 and i < plants.size():
		plants[i].alien = uid


## Drive the three sources this owns. `alive` answers whether an alien ID is
## still in play; `pos_of` gives its current position, because a roamer walks
## and the scene is what moved it.
func tick(delta: float, player_at: Vector2,
		alive: Callable, pos_of: Callable) -> void:
	_tick_roamers(delta, player_at, alive, pos_of)
	_tick_plants(delta, player_at, alive)
	_tick_patches(player_at)


func _tick_roamers(delta: float, player_at: Vector2,
		alive: Callable, pos_of: Callable) -> void:
	for r in roamers:
		var idx: int = r.alien
		if idx < 0 or not alive.call(idx):
			# Dead, and with it the escorts it was calling up. This is the off
			# switch: the brood stops because its source stopped.
			continue
		var at: Vector2 = pos_of.call(idx)
		r.pos = at
		if at.distance_to(player_at) > cfg.roamer_notice_m:
			continue
		r.brood_cd -= delta
		if r.brood_cd <= 0.0:
			r.brood_cd = cfg.roamer_brood_interval_s
			brood_due.emit(at, cfg.roamer_brood_count, &"roamer")


func _tick_plants(delta: float, player_at: Vector2, alive: Callable) -> void:
	for p in plants:
		var idx: int = p.alien
		if idx < 0 or not alive.call(idx):
			# Killed. A plant that is dead stops calling, which is the only way
			# to stop it — walking back out of range does not.
			p.awake = false
			continue
		var at: Vector2 = p.pos
		if not p.awake:
			if at.distance_to(player_at) > cfg.plant_notice_m:
				continue
			p.awake = true
			p.brood_cd = cfg.plant_brood_interval_s * 0.4
			woke.emit(&"plant", at)
		p.brood_cd -= delta
		if p.brood_cd <= 0.0:
			p.brood_cd = cfg.plant_brood_interval_s
			brood_due.emit(at, cfg.plant_brood_count, &"plant")


func _tick_patches(player_at: Vector2) -> void:
	for q in patches:
		if q.spent:
			continue
		var at: Vector2 = q.pos
		if at.distance_to(player_at) > cfg.patch_notice_m:
			continue
		q.spent = true
		var n := _rng.randi_range(cfg.patch_count_min, cfg.patch_count_max)
		woke.emit(&"patch", at)
		brood_due.emit(at, n, &"patch")


## Where a roamer wants to walk next: a point inside its territory, re-rolled
## when it arrives. Called by the scene, which owns the movement.
func roamer_goal(i: int, at: Vector2) -> Vector2:
	var r := roamers[i]
	var goal: Vector2 = r.goal
	if at.distance_to(goal) > 1.5:
		return goal
	for _t in 12:
		var a := _rng.randf() * TAU
		var d: float = _rng.randf() * cfg.roamer_wander_m
		var p: Vector2 = (r.home as Vector2) + Vector2(cos(a), sin(a)) * d
		if _field.is_passable(p):
			r.goal = p
			return p
	return at


## Somewhere a brood can come up: passable ground near `at`, so a group does
## not surface inside a cliff.
func emerge_point(at: Vector2, radius: float) -> Vector2:
	for _t in 10:
		var a := _rng.randf() * TAU
		var p := at + Vector2(cos(a), sin(a)) * (radius * sqrt(_rng.randf()))
		if _field.is_passable(p):
			return p
	return at


## METRES, not cells. is_passable() takes world metres and the map is currently
## 1 m per cell, so the two are the same number today and a cell-space point
## would have looked completely correct — right up until the day cell_size_m
## changes, when every roamer, nest and patch would quietly bunch into one
## corner of the map.
func _open_point() -> Vector2:
	var cfg_t := _field.cfg
	var s: float = cfg_t.cell_size_m
	var w: float = cfg_t.cells_x * s
	var h: float = cfg_t.cells_z * s
	for _t in 60:
		var p := Vector2(_rng.randf_range(4.0 * s, w - 4.0 * s),
			_rng.randf_range(4.0 * s, h - 4.0 * s))
		if _field.is_passable(p) and not _field.is_rough(p):
			return p
	return Vector2(w * 0.5, h * 0.5)


func _shuffle(a: Array) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var t: Variant = a[i]
		a[i] = a[j]
		a[j] = t
