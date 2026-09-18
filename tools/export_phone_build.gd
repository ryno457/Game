extends SceneTree
## Assemble a self-contained Godot project for the phone, and prove it is
## actually self-contained before handing it over.
##
##   godot --headless --path . --script tools/export_phone_build.gd
##
## The Android editor from the Play Store opens a project folder and runs its
## main scene. It cannot use an APK export preset — dl.google.com is blocked by
## the egress policy here, so apksigner and the Android SDK are unreachable and
## this machine cannot build an APK at all. A project folder is the whole of
## what can be delivered, and it is enough: the tester opens it and presses
## play.
##
## The nested spike project, the tools, the docs and the JS prototype are left
## out. `spikes/` in particular is a second project.godot inside the first,
## which the phone would spend a minute importing for no reason.

const OUT := "res://build/phone/sentinel"
## Copied whole. Everything the running game touches lives in one of these.
const DIRS := ["autoload", "data", "models", "scenes", "scripts", "shaders",
	"textures"]
const FILES := ["project.godot"]
## Left behind, and why, so this list is a decision rather than an oversight.
const SKIPPED := {
	"spikes/": "a second Godot project inside the first",
	"tools/": "headless scripts; nothing at runtime loads them",
	"docs/": "text",
	"prototype/": "the old JS prototype",
	"tests/": "not shipped",
	"build/": "output",
}

var _failed := 0
var _copied := 0
var _bytes := 0


func _initialize() -> void:
	print("SENTINEL — phone build\n")
	var root := ProjectSettings.globalize_path(OUT)
	_wipe(root)
	DirAccess.make_dir_recursive_absolute(root)

	for f in FILES:
		_copy_file("res://" + f, OUT + "/" + f)
	for d in DIRS:
		_copy_dir("res://" + d, OUT + "/" + d)
	_write_readme()

	print("  %d files, %.1f MB" % [_copied, _bytes / 1048576.0])
	print("\n  left out:")
	for k in SKIPPED:
		print("    %-14s %s" % [k, SKIPPED[k]])

	_check()
	print("")
	if _failed == 0:
		print("PHONE BUILD: OK — %s" % OUT)
	else:
		print("%d CHECK(S) FAILED" % _failed)
	quit(_failed)


func _ok(name: String, cond: bool, detail: String) -> void:
	if not cond:
		_failed += 1
	print("  %s  %s  %s" % ["PASS" if cond else "FAIL", name.rpad(40), detail])


func _wipe(abs_path: String) -> void:
	var d := DirAccess.open(abs_path)
	if d == null:
		return
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if d.current_is_dir():
			_wipe(abs_path.path_join(n))
			DirAccess.remove_absolute(abs_path.path_join(n))
		else:
			DirAccess.remove_absolute(abs_path.path_join(n))
		n = d.get_next()
	d.list_dir_end()


func _copy_file(src: String, dst: String) -> void:
	var data := FileAccess.get_file_as_bytes(src)
	if data.is_empty() and FileAccess.get_open_error() != OK:
		print("  FAILED to read %s" % src)
		_failed += 1
		return
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(dst.get_base_dir()))
	var f := FileAccess.open(dst, FileAccess.WRITE)
	f.store_buffer(data)
	f.close()
	_copied += 1
	_bytes += data.size()


func _copy_dir(src: String, dst: String) -> void:
	for f in DirAccess.get_files_at(src):
		# .uid files belong to the project that generated them. Copying the
		# parent project's ids into a new project is how you get two ids for
		# one script; the import pass in tools/phone_build.sh regenerates a
		# correct set inside the exported folder, which is what ends up in the
		# zip. The .tres and .tscn files here reference scripts BY PATH, not by
		# uid, so nothing depends on the ids matching across the copy.
		if f.ends_with(".uid"):
			continue
		_copy_file(src + "/" + f, dst + "/" + f)
	for sub in DirAccess.get_directories_at(src):
		_copy_dir(src + "/" + sub, dst + "/" + sub)


func _write_readme() -> void:
	var text := """SENTINEL — phone test build

WHAT THIS IS
  A Godot project folder, not an APK. This machine cannot build an APK:
  dl.google.com is blocked by the egress policy, so the Android SDK and
  apksigner are unreachable. Open the folder in the Godot editor instead.

HOW TO RUN IT
  1. Unzip somewhere on the phone (Files / your unzip app of choice).
  2. Open Godot 4.7.2 from the Play Store.
  3. Import / Open, and pick the folder containing project.godot.
  4. Wait for the first import — a few hundred files, about a minute.
  5. Press Play. It opens straight into the prototype.

THIS BUILD IS LANDSCAPE. Turn the phone sideways before you open it.

WHAT YOU ARE LOOKING AT
  The map is the FLOOR OF A MOUNTAIN RAVINE seen from almost overhead:
  plateaus joined by narrow necks, with a chasm where the ground runs out and
  rock walls climbing past it on every side. Everything outside a plateau is
  the drop, not ground. The necks are nine or ten metres wide — they are
  chokepoints on purpose.

  Top bar      module mass and how much of the map you have uncovered
  Top left     the corner map: fog, contacts, and where the camera is
  Centre       alerts, and the bar for whatever the drone is freeing
  Right        radar, then the build tiles (scrolls vertically)
  Bottom left  the reforge panel, when machines are selected
  Bottom right what the drone is working on

WHAT TO DO
  PINCH        two fingers to zoom. Three levels: wide, middle, close. The
               pinch runs smoothly and settles on the nearest level when you
               lift off.
  ZOOM         top of the right-hand column. Steps through the same three
               levels and says which one you are on.
  Drag         pan the camera. The camera follows the module on a LEASH: your
               pan is left where you put it until the module walks far enough
               out that it would leave the screen.
  Tap ground   the module WALKS there. It does not appear there. It is SLOW
               on purpose — about 40 seconds to cross the map — and it can be
               caught out of position, which is the point of a body that
               carries your mass.
  Tap a piece  sends the drone to collect it. ANY piece: loose debris, a
               wreck, or a big stuck one. THE DRONE NEVER COLLECTS ON ITS
               OWN — if nothing is happening to your mass, nothing has been
               ordered. The panel bottom right says so.
  Tap a machine    select it; tap more to add them to the selection
  Tap empty ground clears the selection
  TRENCH       toggle, then drag to dig. Digging costs no mass, only time.
  Build tiles  right-hand column. Name, role, mass cost.
  Reforge      bottom left, when something is selected. It offers everything
               that pooled mass could become. Two machines reach things one
               cannot.
  QUALITY      cycles High -> Medium -> Low, and RESTARTS the timings.

WHAT IS NEW TO LOOK AT
  SHOTS TRAVEL. Machines throw a visible bolt or an arcing shell rather than
  damaging things instantly. A shot that loses its target keeps going: a
  shell still lands, a bolt misses. Watch whether a firefight now reads as a
  firefight.

  HEALTH BARS. Over machines, the module, the roaming creatures and the
  plant nests always; over a small alien only once it is hurt. Friendly bars
  run green to red, hostile bars run the other way round, because a nearly
  dead hostile is good news. Tell me if that reads backwards to you.

  The module's bar is its MASS, which is the same number as the top bar.

THE HIVE — FOUR WAYS TO START A FIGHT, AND FOUR WAYS TO END ONE
  The map starts QUIET. Two large creatures roam it in the open and
  everything else is underground. Every fight is something you did, and
  every one of them has an off switch you can reach:

    1. Tap a big debris piece   the drone goes to free it, and they come
                                while it works. Freeing it ENDS the attack.
    2. Walk near an alien plant it wakes and keeps calling. Backing away
                                does NOT stop it — only KILLING IT does.
    3. Step on bare ground      some of it has three or four buried under
                                it. One group, then that patch is spent.
    4. Walk up to a roamer      it calls escorts while you are close.
                                KILL THE BIG ONE and the escorts stop.

  Anything that comes up spends about a second and a half CLIMBING OUT
  before it can move. That is your warning, and it is deliberate.

  WHAT TO TELL ME: whether the off switches READ. Killing a plant should
  feel like you turned something off. If a fight just seems to stop on its
  own, or you cannot tell which thing is producing the aliens chewing on
  you, that is the bug — not the numbers.

  Known thin: freeing a large piece takes about 26 s against a 45 s wave
  interval, so trigger 1 currently delivers exactly ONE group. It is the
  lightest of the four. Tell me if it should bite harder.

QUALITY PRESETS
  High    4x MSAA, full resolution, terrain surface detail on
  Medium  2x MSAA, everything else identical to High
  Low     no MSAA (FXAA instead), 85% resolution, no surface detail

  Medium exists so a failure is diagnostic. If High misses 60fps and Medium
  holds it, the cost was the antialiasing. If Medium misses too, it is the
  terrain shader or the prop count.

  Switching presets restarts the frame timings on purpose: a session that
  ran three minutes on High and two on Low reports one blended number that
  describes neither.

WHAT I NEED BACK
  Tap PERF (far right of the build bar) and play for at least two minutes
  ON EACH PRESET, photographing the card each time. Under two minutes it
  refuses to give a verdict rather than report a number off a cold phone.

  Tap TEST LOAD to jam twelve heavy machines and sixty hostiles onto the
  field at once and open the fog. That is the worst case, and it is the
  number that matters most. It injects mass from nowhere, which the game's
  conservation rule forbids — it says so on screen, it is instrumentation.

  The three numbers to photograph: p95 frame time, worst minute, drift.
  Also useful: draw calls and the props-drawn count, and whether it gets
  hot and slow after ten minutes.

WHAT IS KNOWN TO BE UNMEASURED
  Spike A said deformable terrain holds 60fps on a Galaxy A54 — but it
  measured the terrain UNLIT and UNDRESSED, and its p95 landed exactly on
  16.67 ms with no margin. Since then this has gained a lighting rig, an
  emissive terrain shader and 457 instanced props. The phone number is
  genuinely unknown. That is what this build is for.
"""
	var f := FileAccess.open(OUT + "/README.txt", FileAccess.WRITE)
	f.store_string(text)
	f.close()
	_copied += 1
	_bytes += text.length()


# --- is it actually self-contained ------------------------------------------
## Every res:// path mentioned in the copied text files must exist in the copy.
##
## This is the check that matters. A phone build that is missing one .tres
## fails on the device, in front of the person testing it, with a stack trace
## they have to photograph — and the round trip is a day. The same mistake has
## already happened once in this project: an export preset that was gitignored
## and never shipped, after a commit message said it had.
func _check() -> void:
	print("\nis it self-contained")
	var missing := PackedStringArray()
	var scanned := 0
	var refs := 0
	var templates := 0
	for path in _all_files(OUT):
		if not (path.ends_with(".gd") or path.ends_with(".tres")
				or path.ends_with(".tscn") or path.ends_with(".godot")
				or path.ends_with(".import") or path.ends_with(".gdshader")):
			continue
		scanned += 1
		var text := FileAccess.get_file_as_string(path)
		for m in RegEx.create_from_string('res://[A-Za-z0-9_./-]+').search_all(text):
			var want: String = m.get_string()
			# The import cache is regenerated by the editor on first open.
			if want.begins_with("res://.godot/"):
				continue
			# A FORMAT STRING, not a path: "res://textures/machine_%s_n.png".
			# The regex stops at the % and hands back a prefix that is not
			# meant to resolve, so checking it reports a miss for a file that
			# was never named. The check cannot verify a path built at runtime
			# and should not pretend to — but it must not skip silently
			# either, or a genuine typo inside a template becomes invisible.
			if m.get_end() < text.length() and text[m.get_end()] == "%":
				templates += 1
				continue
			refs += 1
			# A constant ending in "/" is a directory the code will list at
			# runtime (OPTIONS_DIR, the model folder). Those have to exist as
			# directories, not as files.
			var here := OUT + want.substr(5)
			var found := DirAccess.dir_exists_absolute(
				ProjectSettings.globalize_path(here)) if want.ends_with("/") \
				else FileAccess.file_exists(here)
			if not found and not missing.has(want):
				missing.append(want)
	for m in missing:
		print("      MISSING  %s" % m)
	if templates > 0:
		print("      (%d runtime-built paths skipped: a static scan cannot"
			% templates + " resolve a format string)")
	_ok("every res:// reference resolves", missing.is_empty(),
		"%d references across %d files" % [refs, scanned])

	# The things a phone needs to even start.
	_ok("the project file came across", FileAccess.file_exists(OUT + "/project.godot"), "")
	var proj := FileAccess.get_file_as_string(OUT + "/project.godot")
	_ok("it still opens on the prototype", proj.contains("proto_main.tscn"),
		"main scene set")
	_ok("it is still a mobile-renderer project", proj.contains('"mobile"'),
		"Vulkan mobile")
	_ok("the models came across",
		DirAccess.get_files_at(OUT + "/models").size() >= 28,
		"%d files" % DirAccess.get_files_at(OUT + "/models").size())
	_ok("the biodome came across",
		FileAccess.file_exists(OUT + "/data/terrain/biodome_map_01.tres")
			and FileAccess.file_exists(OUT + "/data/biomes/biodome_01_palette.tres")
			and FileAccess.file_exists(OUT + "/data/biomes/biodome_01_dressing.tres"),
		"map, palette, dressing")
	_ok("the machine catalogue came across",
		DirAccess.get_files_at(OUT + "/data/machines/parts").size() >= 19,
		"%d parts" % DirAccess.get_files_at(OUT + "/data/machines/parts").size())
	_ok("nothing from the spike came with it",
		not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(OUT + "/spikes")),
		"one project.godot only")
	_ok("the instructions came across", FileAccess.file_exists(OUT + "/README.txt"), "")
	# The brush sheet is the project's only texture asset, and the terrain is
	# unpainted without it — a silent, look-only failure that no other check
	# here would catch.
	_ok("the brush sheet came across",
		FileAccess.file_exists(OUT + "/textures/brush_strokes.png"),
		"the only texture in the project")


func _all_files(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	for f in DirAccess.get_files_at(dir):
		out.append(dir + "/" + f)
	for sub in DirAccess.get_directories_at(dir):
		out.append_array(_all_files(dir + "/" + sub))
	return out
