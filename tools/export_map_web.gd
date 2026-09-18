extends SceneTree
## Bake the biodome into something a web page can draw.
##
##   godot --headless --path . --script tools/export_map_web.gd
##
## Writes build/web/map.png and build/web/map.json, which the browser map
## editor embeds. The point is that the page draws the REAL map — the same
## heights, the same water, the same materials, the same plant positions the
## game scatters — rather than a pretty approximation. A designer placing a
## nest "next to that plant" has to be looking at the plant that is actually
## there.
##
## ONE PNG, THREE CHANNELS: R is height, G is material id, B is water. A
## 150x112 image is about ten kilobytes, which is small enough to inline into
## an artifact, and a canvas can read it back with getImageData without any
## decoding of my own.
##
## AND THE REAL GROUND TEXTURE. The heights alone only ever gave the page a
## height-ramp tint, which is a diagram of the map rather than a picture of it.
## albedo.jpg is the SAME whole-map bake the terrain shader samples, so the
## editor's background is the floor the designer will actually see.

const MAP := "res://data/terrain/biodome_map_01.tres"
const PALETTE := "res://data/biomes/biodome_01_palette.tres"
const DRESSING := "res://data/biomes/biodome_01_dressing.tres"
const HIVE := "res://data/gameplay/hive.tres"
const PLACEMENTS := "res://data/gameplay/hive_placements.tres"
const OUT_DIR := "res://build/web"
## TerrainView.DETAIL_C — the whole-map baked albedo, unwrapped across the
## floor rather than tiled. Not loaded through TerrainView because that would
## drag a whole render path in for one texture.
const ALBEDO := "res://textures/ground_vines_c.png"
## What the page gets, in pixels across.
##
## THE SOURCE IS 2048 AND 3.8 MB, which is not a thing to inline into a web
## page a phone has to open. 1400 at this quality is about 200 kB, which is
## within a rounding error of the map geometry the page already carries, and
## the page never shows the map wider than about 1800 px even zoomed in. It is
## a background to place things against, not an art review.
const ALBEDO_W := 1400
const ALBEDO_Q := 0.84


func _initialize() -> void:
	print("SENTINEL — bake the map for the web editor\n")
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(OUT_DIR))

	var map: TerrainMap = load(MAP)
	var field := TerrainBuilder.build(map)
	var cfg := field.cfg
	var palette: BiomePalette = load(PALETTE)
	TerrainBuilder.classify_materials(field, palette.void_below,
		palette.channel_below, palette.channel_web_threshold, 2.5, 3.0,
		palette.channel_strand_width_m)

	var img := Image.create_empty(cfg.cells_x, cfg.cells_z, false,
		Image.FORMAT_RGB8)
	for z in cfg.cells_z:
		for x in cfg.cells_x:
			var i := z * cfg.cells_x + x
			img.set_pixel(x, z, Color(
				clampf(field.heights[i], 0.0, 1.0),
				# Material ids are small integers; 8 of them over the 0-1 range
				# keeps them distinguishable after the PNG round trip.
				clampf(float(field.material_id[i]) / 8.0, 0.0, 1.0),
				clampf(field.water[i], 0.0, 1.0)))
	var err := img.save_png(OUT_DIR + "/map.png")
	print("  map.png   %dx%d  %s" % [cfg.cells_x, cfg.cells_z,
		"ok" if err == OK else error_string(err)])

	_bake_albedo(cfg)

	# Where the dressing actually puts things, so the page can draw the props
	# the designer will be placing next to.
	var plan: BiomeDressing = load(DRESSING)
	var placed := Dressing.place(field, plan, map.spawn)
	var props: Array = []
	for kind in placed:
		for t in placed[kind]:
			var tr: Transform3D = t
			props.append({"k": String(kind),
				"x": snappedf(tr.origin.x, 0.1),
				"z": snappedf(tr.origin.z, 0.1),
				"s": snappedf(tr.basis.get_scale().y, 0.05)})

	var hive: HiveConfig = load(HIVE)
	var out := {
		"map": MAP,
		"cells_x": cfg.cells_x, "cells_z": cfg.cells_z,
		"cell_size_m": cfg.cell_size_m,
		"impassable_below": cfg.impassable_below,
		# The clamp range, because the web editor reproduces deform() and
		# _disc() exactly — cos(d/r*PI/2) squared, clamped to these — and a
		# preview that disagrees with what the apply tool will do is a preview
		# that lies.
		"clamp_min": cfg.clamp_min,
		"clamp_max": cfg.clamp_max,
		"rough_below": cfg.rough_below,
		"height_scale_m": cfg.height_scale_m,
		"spawn": [map.spawn.x, map.spawn.y],
		"props": props,
		# The Hive's own radii, so the page draws the SAME notice circles the
		# game uses rather than numbers typed twice.
		"hive": {
			"roamer_wander_m": hive.roamer_wander_m,
			"roamer_notice_m": hive.roamer_notice_m,
			"plant_notice_m": hive.plant_notice_m,
			"patch_notice_m": hive.patch_notice_m,
			"patch_spacing_m": hive.patch_spacing_m,
			"plant_brood_count": hive.plant_brood_count,
		},
		# The palette's own ground colours, so the web map is not a second
		# opinion about what this biodome looks like.
		# How much of the baked albedo the shader actually shows over the flat
		# palette colour. The page reproduces the same mix rather than guessing
		# at one, so a floor that looks dark in the editor looks dark in game.
		"baked_colour": palette.baked_colour,
		"colours": {
			"pool": palette.col_pool.to_html(false),
			"rough": palette.col_rough.to_html(false),
			"ground": palette.col_ground.to_html(false),
			"ridge": palette.col_ridge.to_html(false),
		},
	}
	# Anything already hand-placed, so the page opens on the current state of
	# the map rather than on a blank one.
	if ResourceLoader.exists(PLACEMENTS):
		var pl: HivePlacements = load(PLACEMENTS)
		if pl != null and not pl.is_empty():
			out["placed"] = {
				"roamers": _pairs(pl.roamers),
				"nests": _pairs(pl.nests),
				"patches": _pairs(pl.patches),
			}

	var f := FileAccess.open(OUT_DIR + "/map.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(out))
	f.close()
	print("  map.json  %d props, %.0f x %.0f m" % [props.size(),
		cfg.cells_x * cfg.cell_size_m, cfg.cells_z * cfg.cell_size_m])
	quit(0)


## The whole-map albedo, small enough to inline.
##
## RESIZED TO THE MAP'S ASPECT, not the texture's. The shader samples it with
## v_world.xz / field_size_m, which stretches a 2048x1526 bake across a
## 150x112 m floor. Baking that stretch in here means the browser draws the
## image into the map rectangle one-to-one and cannot introduce a second,
## different stretch of its own.
func _bake_albedo(cfg: TerrainConfig) -> void:
	var src := Image.load_from_file(ALBEDO)
	if src == null:
		print("  albedo    MISSING %s — the page will fall back to the "
			% ALBEDO + "height ramp")
		return
	var h := int(round(ALBEDO_W * float(cfg.cells_z) / float(cfg.cells_x)))
	src.resize(ALBEDO_W, h, Image.INTERPOLATE_LANCZOS)
	var out := OUT_DIR + "/albedo.jpg"
	var e := src.save_jpg(out, ALBEDO_Q)
	var kb := 0.0
	var f := FileAccess.open(out, FileAccess.READ)
	if f != null:
		kb = f.get_length() / 1024.0
		f.close()
	print("  albedo.jpg %dx%d  %.0f kB  %s" % [ALBEDO_W, h, kb,
		"ok" if e == OK else error_string(e)])


func _pairs(v: Array[Vector2]) -> Array:
	var out: Array = []
	for p in v:
		out.append([snappedf(p.x, 0.1), snappedf(p.y, 0.1)])
	return out
