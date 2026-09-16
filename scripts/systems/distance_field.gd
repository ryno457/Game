class_name DistanceField
extends RefCounted
## Distance from every cell to the nearest cell of interest.
##
## WHY THIS EXISTS. Look closely at the reference map and almost every gradient
## in it is a distance: ground darkens as it approaches the edge of the mass,
## lightens away from a root strand, and pales toward a waterline. Those are not
## height ramps — two places at the same height shade differently depending on
## how far they are from a FEATURE. A height-banded shader cannot express that,
## which is why the current one looks flat and posterised.
##
## A distance field is the input that makes those gradients possible, and it is
## smooth by construction: the value changes by about one per cell, so any ramp
## built on it is continuous everywhere.
##
## TWO-PASS CHAMFER, not a brute-force search and not jump flooding. Brute force
## is O(cells x radius^2) and jump flooding wants a GPU. The chamfer transform
## is two sweeps over the grid — O(cells), a couple of milliseconds for 16,800
## cells — and its error against true Euclidean distance is under 2% with the
## 5-7-11 weights below, which is far tighter than anything a colour ramp can
## show.

## Chamfer weights, scaled by 5 so they stay integral: 5 orthogonal, 7 diagonal,
## 11 knight's-move. The third term is what gets the error under 2%; with only
## 5 and 7 it is nearer 8% and the ramps visibly bulge along the diagonals.
const ORTHO := 5.0
const DIAG := 7.0
const KNIGHT := 11.0
const SCALE := 1.0 / 5.0

const FAR := 1.0e9


## Distance in CELLS from each cell to the nearest cell where `seed` is true.
##
## `seed` is a PackedByteArray parallel to the grid — 1 marks a source. Returns
## a float per cell; cells with no reachable source come back as `max_m`.
static func compute(seed: PackedByteArray, w: int, h: int,
		max_m: float = 24.0) -> PackedFloat32Array:
	var d := PackedFloat32Array()
	d.resize(w * h)
	for i in w * h:
		d[i] = 0.0 if seed[i] == 1 else FAR

	# Forward sweep: every cell can only be improved by neighbours already
	# visited, which is what makes two passes sufficient.
	for z in h:
		for x in w:
			var i := z * w + x
			if d[i] == 0.0:
				continue
			var best := d[i]
			best = minf(best, _at(d, w, h, x - 1, z) + ORTHO)
			best = minf(best, _at(d, w, h, x, z - 1) + ORTHO)
			best = minf(best, _at(d, w, h, x - 1, z - 1) + DIAG)
			best = minf(best, _at(d, w, h, x + 1, z - 1) + DIAG)
			best = minf(best, _at(d, w, h, x - 2, z - 1) + KNIGHT)
			best = minf(best, _at(d, w, h, x + 2, z - 1) + KNIGHT)
			best = minf(best, _at(d, w, h, x - 1, z - 2) + KNIGHT)
			best = minf(best, _at(d, w, h, x + 1, z - 2) + KNIGHT)
			d[i] = best

	# Backward sweep, mirrored.
	for z in range(h - 1, -1, -1):
		for x in range(w - 1, -1, -1):
			var i := z * w + x
			if d[i] == 0.0:
				continue
			var best := d[i]
			best = minf(best, _at(d, w, h, x + 1, z) + ORTHO)
			best = minf(best, _at(d, w, h, x, z + 1) + ORTHO)
			best = minf(best, _at(d, w, h, x + 1, z + 1) + DIAG)
			best = minf(best, _at(d, w, h, x - 1, z + 1) + DIAG)
			best = minf(best, _at(d, w, h, x + 2, z + 1) + KNIGHT)
			best = minf(best, _at(d, w, h, x - 2, z + 1) + KNIGHT)
			best = minf(best, _at(d, w, h, x + 1, z + 2) + KNIGHT)
			best = minf(best, _at(d, w, h, x - 1, z + 2) + KNIGHT)
			d[i] = best

	for i in w * h:
		d[i] = minf(d[i] * SCALE, max_m)
	return d


static func _at(d: PackedFloat32Array, w: int, h: int, x: int, z: int) -> float:
	if x < 0 or x >= w or z < 0 or z >= h:
		return FAR
	return d[z * w + x]


## Normalise a field to 0..1 over `range_m`, for packing into a texture channel.
static func to_bytes(d: PackedFloat32Array, range_m: float) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(d.size())
	for i in d.size():
		out[i] = int(clampf(d[i] / maxf(0.001, range_m), 0.0, 1.0) * 255.0)
	return out
