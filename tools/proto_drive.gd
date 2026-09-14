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
	_ok("something was built", scene.built.size() == 1, "%d on the field" % scene.built.size())
	# Measured with no steps in between: the drone is still working, and it
	# banks more than a Bulwark costs, so stepping first hides the shrink.
	_ok("module shrinks the moment mass is spent", scene.mass.display_scale() < before_scale,
		"scale %.3f -> %.3f" % [before_scale, scene.mass.display_scale()])

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

	print("")
	if _failed == 0:
		print("LOOP TURNS — collect, grow, build, commit, hold, bank.")
	else:
		print("%d CHECK(S) FAILED" % _failed)
	return true    # done — end the main loop


func _ok(name: String, cond: bool, detail: String) -> void:
	if not cond:
		_failed += 1
	print("  %s  %s  %s" % ["PASS" if cond else "FAIL", name.rpad(40), detail])
