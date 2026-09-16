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

	# Optionally reveal the whole map before capturing.
	#
	# Not a cheat for a prettier picture — it is what makes the frame COMPARABLE.
	# 91% of the map is fogged at the start, so a shot of the real opening state
	# is mostly unlit ground, and measuring it against a painting (which has no
	# fog at all) scores the fog rather than the art. tools/look_check.py wants
	# the revealed one; a shot of what the player actually sees on frame one
	# wants the fogged one. Both are worth having, which is why this is a flag.
	var reveal: bool = argv.size() > 2 and argv[2] == "reveal"
	var white := _white()

	var ps: PackedScene = load("res://scenes/proto/proto_main.tscn")
	if ps == null:
		push_error("no main scene")
		quit(1)
		return
	root.add_child(ps.instantiate())

	for i in frames:
		await process_frame
		if reveal:
			_reveal_all(root, white)
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


## Open the fog, by handing the terrain a fog map that is white everywhere.
##
## FogOfWar is a RefCounted held by the prototype, not a node, so there is
## nothing in the tree to reach for. Overriding the shader uniform is both
## simpler and more robust: the game keeps uploading its own fog into its own
## ImageTexture, and the terrain is simply no longer pointed at it. A 1x1 white
## texture is enough — the sampler is filter_linear, repeat_disable, so every
## sample of it returns 1.0.
##
## Re-applied every frame because apply_palette() can re-bind the real map.
func _reveal_all(n: Node, white: Texture2D) -> void:
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		var m: Material = mi.material_override
		if m == null and mi.mesh != null:
			m = mi.get_active_material(0)
		if m is ShaderMaterial:
			var sm := m as ShaderMaterial
			if sm.shader != null and sm.shader.resource_path.ends_with(
					"terrain_lit.gdshader"):
				sm.set_shader_parameter("fog_map", white)
	for c in n.get_children():
		_reveal_all(c, white)


static func _white() -> Texture2D:
	var img := Image.create_empty(1, 1, false, Image.FORMAT_R8)
	img.set_pixel(0, 0, Color(1, 1, 1))
	return ImageTexture.create_from_image(img)
