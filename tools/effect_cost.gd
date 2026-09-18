extends SceneTree
## What does each effect cost, on its own?
##
##   tools/effect_cost.sh
##
## READ THE CAVEAT BEFORE THE NUMBERS. This machine has no GPU: it renders
## through lavapipe, Mesa's software Vulkan. A software rasteriser gets the
## ORDERING of fragment and vertex work roughly right and the absolute numbers
## completely wrong, and it is nothing like a tiler under thermal throttle.
##
## So this answers "which of these four costs meaningfully more than the
## others, and is any of them a disaster" — which is worth knowing before
## shipping four effects to a phone. It does NOT answer "can the A54 afford
## this". Only the A54 can, and the EFFECTS button in the test build is how it
## gets asked.
##
## Each rung is measured against the SAME scene under the SAME load, with only
## one effect on, and against a "none" baseline. A run that measured them all
## together would report one number describing none of them.

const SCENE := "res://scenes/proto/proto_main.tscn"
## Frames thrown away before each rung is timed. Shader compilation, the first
## scenery cull and the fog settling all happen in the first second and would
## otherwise be charged to whichever effect went first.
const WARMUP := 40
const SAMPLE := 110


func _initialize() -> void:
	print("SENTINEL — what each effect costs\n")
	print("renderer: %s\n" % RenderingServer.get_video_adapter_name())
	var scene := (load(SCENE) as PackedScene).instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame

	# A real load, not an empty map: an effect that is free with nothing on
	# screen tells you nothing. Twelve machines, sixty hostiles, fog open.
	scene.call("_stress")
	for i in 10:
		await process_frame

	# TWO PASSES, THE SECOND IN REVERSE, averaged.
	#
	# The first version of this ran each rung once in order and reported every
	# single effect as FASTER than no effects at all — which is impossible, and
	# was the machine warming up: a steady downward drift across the run,
	# aliased onto rung order. Measuring forwards and then backwards makes a
	# monotonic drift cancel, and measuring "none" at both ends gives a NOISE
	# FLOOR to compare the differences against. A difference smaller than the
	# floor is not a measurement, and this says so rather than printing it.
	var sums: Dictionary = {}
	var each: Dictionary = {}
	var draws: Dictionary = {}
	var order: Array = []
	for i in scene.FX_MODES.size():
		order.append(i)
	var reversed_order: Array = order.duplicate()
	reversed_order.reverse()
	var first_none := 0.0
	var last_none := 0.0

	for pass_i in 2:
		var seq: Array = order if pass_i == 0 else reversed_order
		for mode in seq:
			scene._fx_mode = (int(mode) - 1 + scene.FX_MODES.size()) \
				% scene.FX_MODES.size()
			scene.call("_cycle_effects")
			var mode_name: String = scene.FX_MODES[scene._fx_mode]
			# Keep the fight alive: the machines kill the hostiles faster than
			# a rung takes to measure, and an empty map is not the load.
			for i in WARMUP:
				if i % 25 == 0:
					scene.call("_spawn_hostiles", 20, 2.0)
				await process_frame
			scene.probe.reset()
			var t0 := Time.get_ticks_usec()
			for i in SAMPLE:
				if i % 25 == 0:
					scene.call("_spawn_hostiles", 20, 2.0)
				await process_frame
			var wall := float(Time.get_ticks_usec() - t0) / 1000.0 / SAMPLE
			sums[mode_name] = float(sums.get(mode_name, 0.0)) + wall * 0.5
			if not each.has(mode_name):
				each[mode_name] = []
			(each[mode_name] as Array).append(wall)
			draws[mode_name] = scene.probe.draw_calls
			if mode_name == "none":
				if pass_i == 0:
					first_none = wall
				else:
					last_none = wall
			print("    pass %d  %-16s %7.1f ms" % [pass_i + 1, mode_name, wall])

	var base := float(sums.get("none", 0.0))
	# THE NOISE FLOOR IS THE WORST DISAGREEMENT BETWEEN TWO PASSES OF THE SAME
	# RUNG, not the drift in "none".
	#
	# The first version used the drift in "none" alone and reported a 9 ms
	# floor while one rung had measured 488 ms in pass 1 and 266 ms in pass 2 —
	# the same code, twice, 222 ms apart. (That run had a screenshot render
	# competing for the CPU, which is its own lesson: measure nothing while
	# anything else is running.) A floor that ignores how badly a rung
	# disagrees with ITSELF will happily certify a number the run cannot
	# reproduce.
	var floor_ms := absf(first_none - last_none)
	for key in each:
		var runs: Array = each[key]
		if runs.size() >= 2:
			floor_ms = maxf(floor_ms, absf(float(runs[0]) - float(runs[1])))
	print("\n  %-16s %10s %10s %8s" % ["rung", "ms/frame", "vs none", "draws"])
	for key in sums:
		var d: float = float(sums[key]) - base
		var verdict := "%+.1f" % d
		if key != "none" and absf(d) < floor_ms:
			verdict = "under noise"
		print("  %-16s %10.1f %10s %8d" % [key, sums[key], verdict, draws[key]])
	print("\n  noise floor %.1f ms — the worst a rung disagreed with ITSELF"
		% floor_ms)
	print("  between the two passes. Nothing smaller than this is a result.")
	for key in each:
		var runs: Array = each[key]
		if runs.size() >= 2 and absf(float(runs[0]) - float(runs[1])) > 40.0:
			print("    %s: %.0f then %.0f — that rung did not repeat"
				% [key, runs[0], runs[1]])
	print("\nSOFTWARE RASTERISER, and a slow one: whole-frame times here are")
	print("around 300 ms, so an effect costing a phone 0.3 ms is far below")
	print("anything this can see. What this run CAN say is that none of the")
	print("four is a disaster. The A54 is the only thing that can price them,")
	print("and the EFFECTS button is how it gets asked.")
	quit()
