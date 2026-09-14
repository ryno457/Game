class_name FogOfWar
extends RefCounted
## Reveal state over the terrain grid, as data plus a texture the shader reads.
##
## Two levels, because they answer different questions: EXPLORED is "I have
## seen this ground" and stays; VISIBLE is "I can see it right now" and follows
## the module. Explored terrain stays dimly drawn, and live contacts only show
## inside VISIBLE.
##
## Everything here is O(cells revealed), never O(grid). The first version
## cleared and rebuilt all 16,800 cells per frame in GDScript, which is the
## same class of cost that made unit updates the most expensive thing in
## Spike A. A frame now touches only the ~1,500 cells a reveal actually covers.

const HIDDEN := 0.0
const EXPLORED := 0.45
const VISIBLE := 1.0

const _EXPLORED_BYTE := 115          ## EXPLORED * 255, precomputed
const UPLOAD_HZ := 12.0              ## fog does not need 60 Hz

var cells: Vector2i
var cell_size: float
var explored: PackedByteArray

var _stamp: PackedInt32Array         ## frame index when a cell was last seen
var _frame := 0
var _lit: PackedInt32Array           ## cells lit this frame
var _prev_lit: PackedInt32Array
var _data: PackedByteArray           ## what the shader samples
var _img: Image
var _tex: ImageTexture
var _dirty := true
var _upload_cd := 0.0
var _explored_count := 0


func _init(grid: Vector2i, p_cell_size: float) -> void:
	cells = grid
	cell_size = p_cell_size
	var n := cells.x * cells.y
	explored = PackedByteArray()
	explored.resize(n)
	_stamp = PackedInt32Array()
	_stamp.resize(n)
	_stamp.fill(-1)
	_data = PackedByteArray()
	_data.resize(n)
	_lit = PackedInt32Array()
	_prev_lit = PackedInt32Array()
	_img = Image.create_empty(cells.x, cells.y, false, Image.FORMAT_R8)
	_tex = ImageTexture.create_from_image(_img)


func texture() -> ImageTexture:
	return _tex


## Demote last frame's lit cells to explored, then start a new frame. Only the
## cells that were actually lit get touched.
func begin_frame() -> void:
	for i in _prev_lit:
		_data[i] = _EXPLORED_BYTE
	_prev_lit = _lit
	_lit = PackedInt32Array()
	_frame += 1
	_dirty = true


func reveal(world_xz: Vector2, radius_m: float) -> void:
	if radius_m <= 0.0:
		return
	var r := radius_m / cell_size
	var cx := world_xz.x / cell_size
	var cz := world_xz.y / cell_size
	var x0 := clampi(int(cx - r), 0, cells.x - 1)
	var x1 := clampi(int(cx + r), 0, cells.x - 1)
	var z0 := clampi(int(cz - r), 0, cells.y - 1)
	var z1 := clampi(int(cz + r), 0, cells.y - 1)
	var r2 := r * r
	for z in range(z0, z1 + 1):
		var row := z * cells.x
		var dz := z - cz
		var dz2 := dz * dz
		for x in range(x0, x1 + 1):
			var dx := x - cx
			if dx * dx + dz2 > r2:
				continue
			var i := row + x
			if _stamp[i] != _frame:
				_stamp[i] = _frame
				_lit.append(i)
			_data[i] = 255
			if explored[i] == 0:
				explored[i] = 1
				_explored_count += 1


func level_at(world_xz: Vector2) -> float:
	var x := clampi(int(world_xz.x / cell_size), 0, cells.x - 1)
	var z := clampi(int(world_xz.y / cell_size), 0, cells.y - 1)
	var i := z * cells.x + x
	if _stamp[i] == _frame:
		return VISIBLE
	return EXPLORED if explored[i] == 1 else HIDDEN


func is_visible(world_xz: Vector2) -> bool:
	var x := clampi(int(world_xz.x / cell_size), 0, cells.x - 1)
	var z := clampi(int(world_xz.y / cell_size), 0, cells.y - 1)
	return _stamp[z * cells.x + x] == _frame


## Kept as a running count rather than a scan, so the HUD can read it freely.
func explored_fraction() -> float:
	return float(_explored_count) / float(explored.size())


## Throttled: the shader does not need a new fog texture every frame, and the
## upload is the only remaining whole-grid operation.
func upload(delta := 0.0) -> void:
	_upload_cd -= delta
	if not _dirty or (delta > 0.0 and _upload_cd > 0.0):
		return
	_upload_cd = 1.0 / UPLOAD_HZ
	_img = Image.create_from_data(cells.x, cells.y, false, Image.FORMAT_R8, _data)
	_tex.update(_img)
	_dirty = false
