extends SceneTree
## Bake the Biodome 01 test map into the Spike A project.
##
## The spike is a standalone Godot project on purpose (deletable in one rm -rf)
## so it cannot reference TerrainMap/TerrainBuilder. It gets a flat binary of
## float32 heights instead, sized exactly to its own sample grid.
##
## The spike works on 160x128 CELLS -> 161x129 SAMPLES (chunk edges are shared),
## while the game map is 150x112. The map is centred into that grid and the
## margin filled with neutral ground, so every feature keeps its true 1 m scale
## and the spike stays slightly LARGER than production, as intended.
##
##   godot --headless --path . --script tools/export_spike_map.gd

const SPIKE_CELLS := Vector2i(160, 128)
const OUT := "res://spikes/01-terrain-perf/data/test_map_01.bin"


func _initialize() -> void:
	var map: TerrainMap = load("res://data/terrain/test_map_01.tres")
	var cfg: TerrainConfig = map.terrain
	var hf := TerrainBuilder.build(map)

	var sx := SPIKE_CELLS.x + 1
	var sz := SPIKE_CELLS.y + 1
	var out := PackedFloat32Array()
	out.resize(sx * sz)
	out.fill(cfg.neutral_height)

	var ox := (sx - cfg.cells_x) / 2
	var oz := (sz - cfg.cells_z) / 2
	for z in cfg.cells_z:
		for x in cfg.cells_x:
			out[(oz + z) * sx + (ox + x)] = hf.heights[z * cfg.cells_x + x]

	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path("res://spikes/01-terrain-perf/data"))
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	f.store_buffer(out.to_byte_array())
	f.close()

	# Spot-check the round trip rather than trusting the offsets.
	var back := FileAccess.open(OUT, FileAccess.READ)
	var raw := back.get_buffer(back.get_length())
	back.close()
	var reread := raw.to_float32_array()
	var ok := reread.size() == sx * sz
	var worst := 0.0
	for z in cfg.cells_z:
		for x in cfg.cells_x:
			worst = maxf(worst, absf(
				reread[(oz + z) * sx + (ox + x)] - hf.heights[z * cfg.cells_x + x]))

	print("spike map: %dx%d samples, offset (%d,%d), %d bytes" % [sx, sz, ox, oz, raw.size()])
	print("round trip: size %s, max divergence %.8f" % ["OK" if ok else "WRONG", worst])
	print("  spawn in spike coords: (%d, %d)" % [ox + int(map.spawn.x), oz + int(map.spawn.y)])
	quit(0 if (ok and worst < 1e-7) else 1)
