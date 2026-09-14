class_name FlowField
extends RefCounted
## One shared navigation field per order group — not per-unit A*.
##
## Dijkstra from the goal produces an integration field (true cost-to-goal per
## cell). Units then just walk downhill on it. The reason this matters for
## SENTINEL: a true distance field has NO local minima, so a freshly dug
## U-shaped trench cannot trap a unit in its pocket. A potential/steering
## field would. That is the whole question Spike B exists to settle.
##
## Plain RefCounted on purpose: no scene tree, no autoloads, fully testable
## under `godot --headless --script`.

signal rebuilt(duration_ms: float)

const INF := 1.0e30
const SQRT2 := 1.4142135623730951
const NO_DIR := 255

## 8-neighbourhood, ordered so index^4 is the opposite direction.
const DIRS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(-1, 1),
	Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
]

var cfg: TerrainConfig
var w: int
var h: int
var goal := Vector2i(-1, -1)

## Burrowers ignore heightfield passability. Everything else is identical,
## which is exactly what makes Burrowing a counter to trench play rather than
## a different movement system.
var ignore_terrain := false
## Uniform-cost mode: rough ground costs the same as clear. Cheaper to build
## (plain BFS) and measurably different in the paths it picks — the scenario
## runner compares the two.
var uniform_cost := false

var integration: PackedFloat32Array
var flow: PackedByteArray
var last_build_ms := 0.0
var last_visited := 0

# Passability and cost, flattened once per rebuild. The first implementation
# called is_passable_cell()/cell_cost() per neighbour — roughly 270k GDScript
# function calls per build, which dominated everything else.
var _pass := PackedByteArray()
var _cost := PackedFloat32Array()

var _heap_i := PackedInt32Array()
var _heap_k := PackedFloat32Array()
var _heap_n := 0


func _init(config: TerrainConfig) -> void:
	cfg = config
	w = cfg.cells_x
	h = cfg.cells_z
	integration = PackedFloat32Array()
	integration.resize(w * h)
	flow = PackedByteArray()
	flow.resize(w * h)
	_pass = PackedByteArray()
	_pass.resize(w * h)
	_cost = PackedFloat32Array()
	_cost.resize(w * h)


func index(cx: int, cz: int) -> int:
	return cz * w + cx


func in_bounds(cx: int, cz: int) -> bool:
	return cx >= 0 and cz >= 0 and cx < w and cz < h


func is_passable_cell(heights: PackedFloat32Array, cx: int, cz: int) -> bool:
	if not in_bounds(cx, cz):
		return false
	if ignore_terrain:
		return true
	return heights[index(cx, cz)] > cfg.impassable_below


## Traversal cost multiplier for entering a cell. Rough ground costs what it
## actually costs: moving at 55% speed is 1/0.55 times the time.
func cell_cost(heights: PackedFloat32Array, i: int) -> float:
	if uniform_cost:
		return 1.0
	if heights[i] < cfg.rough_below:
		return 1.0 / cfg.rough_speed_multiplier
	return 1.0


## Rebuild the whole field. Returns milliseconds spent.
##
## A dig anywhere can change routes anywhere, so this is a full rebuild rather
## than a chunk patch — chunk-local repair is only valid when the dig cannot
## affect connectivity, which is exactly the case a trench breaks. The
## scenario runner measures the cost so the decision to amortize (or not) is
## made against a number.
func build(heights: PackedFloat32Array, goal_cell: Vector2i) -> float:
	var t0 := Time.get_ticks_usec()
	goal = goal_cell
	var n := w * h
	for i in n:
		integration[i] = INF
		flow[i] = NO_DIR

	if not is_passable_cell(heights, goal.x, goal.y):
		last_build_ms = (Time.get_ticks_usec() - t0) / 1000.0
		last_visited = 0
		rebuilt.emit(last_build_ms)
		return last_build_ms

	# One linear pass instead of a function call per neighbour visit.
	var rough := cfg.rough_below
	var imp := cfg.impassable_below
	var rough_mul := 1.0 / cfg.rough_speed_multiplier
	for i in n:
		var hv := heights[i]
		_pass[i] = 1 if (ignore_terrain or hv > imp) else 0
		if uniform_cost:
			_cost[i] = 1.0
		else:
			_cost[i] = rough_mul if hv < rough else 1.0

	_heap_n = 0
	var gi := index(goal.x, goal.y)
	integration[gi] = 0.0
	_push(gi, 0.0)

	var visited := 0
	while _heap_n > 0:
		var key := _heap_k[0]
		var ci := _heap_i[0]
		_pop()
		if key > integration[ci]:
			continue          # stale heap entry
		visited += 1
		var cx := ci % w
		var cz := ci / w

		for d in 8:
			var dir: Vector2i = DIRS[d]
			var nx := cx + dir.x
			var nz := cz + dir.y
			if nx < 0 or nz < 0 or nx >= w or nz >= h:
				continue
			var ni := nz * w + nx
			if _pass[ni] == 0:
				continue
			var step: float = _cost[ni]
			# No corner cutting. Without this a unit slips diagonally through
			# a one-cell-thick trench wall and the trench does nothing.
			if dir.x != 0 and dir.y != 0:
				if _pass[cz * w + nx] == 0 or _pass[nz * w + cx] == 0:
					continue
				step *= SQRT2
			var nd := key + step
			if nd < integration[ni]:
				integration[ni] = nd
				# Store the direction that walks TOWARD the goal, i.e. back
				# along the edge we just relaxed.
				flow[ni] = (d + 4) % 8
				_push(ni, nd)

	last_visited = visited
	last_build_ms = (Time.get_ticks_usec() - t0) / 1000.0
	rebuilt.emit(last_build_ms)
	return last_build_ms


func cost_at_cell(cx: int, cz: int) -> float:
	if not in_bounds(cx, cz):
		return INF
	return integration[index(cx, cz)]


func is_reachable(cx: int, cz: int) -> bool:
	return cost_at_cell(cx, cz) < INF


## Unit direction to walk, in world XZ. Zero when there is no route.
func direction_at(world: Vector2) -> Vector2:
	var cx := clampi(int(world.x / cfg.cell_size_m), 0, w - 1)
	var cz := clampi(int(world.y / cfg.cell_size_m), 0, h - 1)
	var d := flow[index(cx, cz)]
	if d == NO_DIR:
		return Vector2.ZERO
	var v: Vector2i = DIRS[d]
	return Vector2(v.x, v.y).normalized()


# --- binary min-heap ---------------------------------------------------------
func _push(idx: int, key: float) -> void:
	if _heap_n >= _heap_i.size():
		var grown := maxi(256, _heap_i.size() * 2)
		_heap_i.resize(grown)
		_heap_k.resize(grown)
	var i := _heap_n
	_heap_i[i] = idx
	_heap_k[i] = key
	_heap_n += 1
	while i > 0:
		var p := (i - 1) >> 1
		if _heap_k[p] <= _heap_k[i]:
			break
		_swap(i, p)
		i = p


func _pop() -> void:
	_heap_n -= 1
	if _heap_n > 0:
		_heap_i[0] = _heap_i[_heap_n]
		_heap_k[0] = _heap_k[_heap_n]
		var i := 0
		while true:
			var l := i * 2 + 1
			var r := l + 1
			var m := i
			if l < _heap_n and _heap_k[l] < _heap_k[m]:
				m = l
			if r < _heap_n and _heap_k[r] < _heap_k[m]:
				m = r
			if m == i:
				break
			_swap(i, m)
			i = m


func _swap(a: int, b: int) -> void:
	var ti := _heap_i[a]
	_heap_i[a] = _heap_i[b]
	_heap_i[b] = ti
	var tk := _heap_k[a]
	_heap_k[a] = _heap_k[b]
	_heap_k[b] = tk
