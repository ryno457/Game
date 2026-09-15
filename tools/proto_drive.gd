extends SceneTree
## Drive the prototype scene headlessly and assert the loop actually turns.
##
## A clean exit proves only that nothing crashed. This proves the drone
## collects, mass grows, building spends it, the module shrinks, targeting a
## stuck piece starts the attack, and freeing it ends the attack.
##
##   godot --headless --path . --script tools/proto_drive.gd

## 20 Hz, not 60: every assertion here is about state changing, not physics
## fidelity, and simulating several minutes at 60 Hz just burns wall clock.
const DT := 1.0 / 20.0
var _failed := 0
var scene: Node3D


func _initialize() -> void:
	scene = load("res://scenes/proto/proto_main.tscn").instantiate()
	# The tree must not step it as well; this script drives step() itself.
	scene.process_mode = Node.PROCESS_MODE_DISABLED
	root.add_child(scene)


## Checks run here rather than in _initialize. Node _ready() callbacks do not
## fire until the tree takes its first iteration, so anything a scene builds in
## _ready is still null during _initialize — exactly the trap this hit.
func _process(_delta: float) -> bool:
	print("SENTINEL — prototype loop drive\n")

	var start_mass: float = scene.mass.mass
	var start_scale: float = scene.mass.display_scale()
	_ok("starts with configured mass", start_mass > 0.0, "%.0f" % start_mass)
	_ok("debris is on the map", scene.debris.size() > 0,
		"%d pieces (%d large)" % [scene.debris.size(),
			scene.debris.filter(func(d): return d.large).size()])

	# --- collection: run until the drone has banked at least one piece -------
	var t := 0.0
	while t < 90.0 and scene.mass.mass <= start_mass:
		scene.step(DT)
		t += DT
	_ok("drone collects and mass grows", scene.mass.mass > start_mass,
		"%.0f -> %.0f after %.0fs" % [start_mass, scene.mass.mass, t])

	for i in 240:
		scene.step(DT)
	_ok("module grows with mass", scene.mass.display_scale() > start_scale,
		"scale %.2f -> %.2f" % [start_scale, scene.mass.display_scale()])
	_ok("fog opens up as it moves", scene.fog.explored_fraction() > 0.0,
		"%.1f%% seen" % (scene.fog.explored_fraction() * 100.0))

	# --- building: spends mass, module shrinks -------------------------------
	var before_mass: float = scene.mass.mass
	var before_scale: float = scene.mass.display_scale()
	var opt: BuildOption = scene.options[0]
	scene._try_build(opt)
	_ok("building spends mass", scene.mass.mass < before_mass,
		"%s cost %.0f, %.0f -> %.0f" % [opt.display_name, opt.mass_cost,
			before_mass, scene.mass.mass])
	# Measured with no steps in between: the drone is still working, and it
	# banks more than a Bulwark costs, so stepping first hides the shrink.
	_ok("module shrinks the moment mass is spent", scene.mass.display_scale() < before_scale,
		"scale %.3f -> %.3f" % [before_scale, scene.mass.display_scale()])

	# Mass is conserved, so the ONLY price of building is the wait. If the
	# machine appeared instantly there would be no cost at all and repurposing
	# would be free — the trap CLAUDE.md records for free module recall.
	var build_s: float = scene.mass.cfg.build_time_for(scene.spec_for(opt).mass)
	_ok("the machine does not exist yet",
		scene.built.is_empty() and scene.assembling.size() == 1,
		"%.0fs of assembly still to run" % build_s)
	var half := int(build_s * 0.5 / DT)
	for i in half:
		scene.step(DT)
	_ok("still nothing on the field halfway through", scene.built.is_empty(),
		"%.1fs elapsed of %.0fs" % [half * DT, build_s])
	while not scene.assembling.is_empty():
		scene.step(DT)
	_ok("it arrives when the assembly time is up", scene.built.size() == 1,
		"%d on the field after %.0fs" % [scene.built.size(), build_s])

	# --- reforging: two machines walk together and become a bigger one -------
	# The player's rule: if you want something bigger, bring a second machine.
	scene._try_build(opt)
	while not scene.assembling.is_empty():
		scene.step(DT)
	_ok("a second machine joins it", scene.built.size() == 2,
		"%d on the field" % scene.built.size())

	var pool: float = scene.built[0].spec.mass + scene.built[1].spec.mass
	# Appended rather than assigned: `selected` is Array[int], and handing a
	# typed array an untyped literal from another script fails at runtime.
	scene.selected.clear()
	scene.selected.append(scene.built[0].uid)
	scene.selected.append(scene.built[1].uid)
	var solo: Array = MergePlanner.candidates(scene.built[0].spec.mass, scene.options,
		scene.specs, scene.built[0].spec.id)
	var offers: Array = scene.forge_options()
	var target: BuildOption = offers[0]
	var target_mass: float = scene.spec_for(target).mass
	_ok("the pair is offered more than one alone", offers.size() > solo.size(),
		"%d offers alone -> %d together at %.0f mass" % [solo.size(), offers.size(), pool])
	_ok("the pair can reach a heavier machine than either of them",
		target_mass > scene.built[0].spec.mass,
		"%s at %.0f mass" % [target.display_name, target_mass])

	# Every gram in the world, wherever it is — module body, standing machines,
	# committed builds, wrecks, uncollected debris, the drone's claw. The drone
	# keeps working through the merge, so a naive module-plus-field total would
	# drift; this one cannot, because collection only moves mass between two of
	# those buckets.
	var before_total: float = scene.system_mass()
	scene._order_merge(target)
	_ok("the order sends them to a rendezvous",
		scene.merging.size() == 1 and scene.merging[0].state == "gathering",
		"converging on %.0f, %.0f" % [scene.merging[0].at.x, scene.merging[0].at.y])
	_ok("both machines are still on the field while they walk", scene.built.size() == 2,
		"nothing disappears until they meet")

	var gather := 0.0
	while gather < 40.0 and not scene.merging.is_empty() \
			and scene.merging[0].state == "gathering":
		scene.step(DT)
		gather += DT
	_ok("they meet and the old machines come apart",
		scene.merging.size() == 1 and scene.merging[0].state == "working"
			and scene.built.is_empty(),
		"met after %.1fs" % gather)

	var work := 0.0
	while work < 40.0 and not scene.merging.is_empty():
		scene.step(DT)
		work += DT
	_ok("the bigger machine exists", scene.built.size() == 1
			and is_equal_approx(scene.built[0].spec.mass, target_mass),
		"%s, %.0f mass, after %.1fs of work"
			% [scene.built[0].spec.display_name, target_mass, work])
	_ok("reforging costs real seconds", work > 1.0, "%.1fs" % work)

	var after_total: float = scene.system_mass()
	_ok("the merge destroyed nothing", is_equal_approx(before_total, after_total),
		"%.1f mass in the system before and after" % before_total)
	_ok("the offcut is lying on the ground, not gone",
		_wreck_mass(scene) >= pool - target_mass - 0.001,
		"%.1f spare from a %.0f pool making a %.0f machine"
			% [pool - target_mass, pool, target_mass])

	# Scrapping returns every gram and costs a drone trip instead.
	var before_scrap: float = scene.mass.mass
	var wrecks_before: int = scene.wrecks.size()
	var scrapped: float = scene.built[0].spec.mass
	scene._scrap(0)
	_ok("scrapping refunds nothing immediately",
		is_equal_approx(scene.mass.mass, before_scrap) and scene.built.is_empty(),
		"%.0f mass unchanged" % scene.mass.mass)
	_ok("scrapping leaves a wreck for the drone",
		scene.wrecks.size() == wrecks_before + 1
			and is_equal_approx(scene.wrecks[-1].mass, scrapped),
		"%.0f mass lying on the ground" % scrapped)

	# --- pacing: quiet until the player commits ------------------------------
	_ok("no attack while only scavenging", not scene.waves.is_active() and scene.aliens.is_empty(),
		"%d hostiles after %.0fs of play" % [scene.aliens.size(), t + 5.5])

	# --- the commitment: free a stuck piece ----------------------------------
	var large := -1
	for i in scene.debris.size():
		if scene.debris[i].large and not scene.debris[i].taken:
			large = i
			break
	_ok("a stuck piece is available", large >= 0, "index %d" % large)
	scene.drone_target = large
	scene.drone_state = "outbound"

	var guard := 0.0
	while guard < 120.0 and not scene.waves.is_active():
		scene.step(DT)
		guard += DT
	_ok("freeing it wakes the hive", scene.waves.is_active(),
		"attack began after %.0fs of travel" % guard)

	var spawn_guard := 0.0
	while spawn_guard < 60.0 and scene.aliens.is_empty():
		scene.step(DT)
		spawn_guard += DT
	_ok("hostiles actually arrive", scene.aliens.size() > 0,
		"%d inbound" % scene.aliens.size())

	# --- and the attack ends when the job does -------------------------------
	var free_guard := 0.0
	while free_guard < 120.0 and scene.waves.is_active():
		scene.step(DT)
		free_guard += DT
	_ok("the attack ends when the piece comes free", not scene.waves.is_active(),
		"held for %.0fs" % free_guard)

	var gained := [0.0]
	scene.mass.changed.connect(func(_m, d): if d > 0.0: gained[0] += d)
	var banked: float = scene.mass.mass
	for i in 900:
		scene.step(DT)
	_ok("the freed piece is credited as mass", gained[0] > 0.0,
		"+%.0f banked while hauling home" % gained[0])
	# Separate and explicit: hostiles eat the module, so the fight has to be
	# survivable or the loop has no counterplay.
	_ok("the module survives the fight it started", scene.mass.mass > 0.0,
		"%.0f mass left (was %.0f when the piece came free)" % [scene.mass.mass, banked])

	# --- presentation and instrumentation ------------------------------------
	# Everything above drives step() only. This is the first thing that touches
	# _present(): the scenery MultiMeshes, the fog cull, the convoy bodies and
	# the frame probe. Headless has no renderer, but every one of these is a
	# GDScript path that can throw, and a phone build that crashes on frame one
	# is not something to discover on the phone.
	_ok("the biodome grew", scene._scenery_total > 0,
		"%d props on the map" % scene._scenery_total)
	for i in 30:
		scene._present(DT)
	_ok("presentation runs", scene.probe.frames == 30,
		"%d frames sampled" % scene.probe.frames)
	_ok("scenery is culled to what has been explored",
		scene._scenery_drawn > 0 and scene._scenery_drawn < scene._scenery_total,
		"%d of %d drawn" % [scene._scenery_drawn, scene._scenery_total])

	var before_units: int = scene.built.size()
	scene._stress()
	for i in 10:
		scene.step(DT)
		scene._present(DT)
	_ok("the test load actually loads the frame",
		scene.built.size() > before_units and scene.aliens.size() >= 60,
		"%d machines, %d hostiles" % [scene.built.size(), scene.aliens.size()])
	_ok("and it opens the map so the props are drawn",
		scene._scenery_drawn > 0, "%d props drawn" % scene._scenery_drawn)

	scene.perf_panel.visible = true
	scene._perf_readout()
	_ok("the frame-time card renders", scene.perf_label.text.contains("VERDICT"),
		"%d characters" % scene.perf_label.text.length())
	# Under the soak floor the card must say so rather than pass a verdict on
	# forty frames of headless play.
	_ok("no verdict before there is data", not scene.probe.verdict().ready,
		"%.0fs of %.0fs" % [scene.probe.elapsed, FrameProbe.MIN_SOAK_S])

	print("")
	if _failed == 0:
		print("LOOP TURNS — collect, grow, build, commit, hold, bank.")
	else:
		print("%d CHECK(S) FAILED" % _failed)
	return true    # done — end the main loop


## Mass lying on the ground waiting for the drone.
func _wreck_mass(s: Node3D) -> float:
	var total := 0.0
	for w in s.wrecks:
		total += w.mass
	return total


func _ok(name: String, cond: bool, detail: String) -> void:
	if not cond:
		_failed += 1
	print("  %s  %s  %s" % ["PASS" if cond else "FAIL", name.rpad(40), detail])
