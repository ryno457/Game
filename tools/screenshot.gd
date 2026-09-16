extends SceneTree
## Save a real frame out of Godot, with every effect on.
##
##   tools/screenshot.sh                       # or, by hand:
##   VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json \
##   xvfb-run -a godot --path . --rendering-driver vulkan \
##       --resolution 1560x720 --script tools/screenshot.gd
##
## Why this exists. Every picture of this game so far has been drawn by a
## DIFFERENT RENDERER — Blender's Cycles, or a numpy port of the shader's own
## arithmetic. Both are useful and both have lied at least once. This one is
## the actual engine: the real terrain shader with its tone ramp, AO, curvature
## and tube shading, the real ink pass, the real cloud deck, the real HUD, the
## real tonemapper.
##
## `--headless` cannot do this. It runs the dummy rasteriser, which compiles no
## shaders and draws nothing, which is exactly why a shader error survives a
## clean headless boot and turns up as a pink screen on the phone.
##
## Frames are given away before the capture because the prototype is not
## finished at frame one: the terrain uploads, the props scatter, the fog
## clears and the shader compiles over the first few frames. Capturing too
## early photographs a half-built map.

const SETTLE_FRAMES := 90
const OUT_DIR := "res://build/shots"


func _initialize() -> void:
	var argv := OS.get_cmdline_user_args()
	var out: String = argv[0] if argv.size() > 0 else "godot_view.png"
	var frames: int = int(argv[1]) if argv.size() > 1 else SETTLE_FRAMES

	print("renderer: ", RenderingServer.get_video_adapter_name(),
		"  (", RenderingServer.get_video_adapter_api_version(), ")")

	var ps: PackedScene = load("res://scenes/proto/proto_main.tscn")
	if ps == null:
		push_error("no main scene")
		quit(1)
		return
	root.add_child(ps.instantiate())

	for i in frames:
		await process_frame
		if i % 30 == 0:
			print("  frame %d/%d" % [i, frames])

	# One more, so the frame we read is the one just presented rather than the
	# one still being built.
	await process_frame
	var img := root.get_texture().get_image()
	if img == null:
		push_error("no viewport image — is this running on a real rasteriser?")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var path := OUT_DIR + "/" + out
	var err := img.save_png(path)
	if err != OK:
		push_error("save failed: %d" % err)
		quit(1)
		return
	print("wrote %s  %dx%d" % [path, img.get_width(), img.get_height()])
	quit()
