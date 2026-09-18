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
var _entered := false
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
	# ONE PASS, EVER. _process returning true is what quits the tree, so a
	# script error partway down means this function never returns and the tree
	# calls it again — the whole suite restarts from the top, forever, against
	# a half-played scene. It looks exactly like a hang, and it cost an
	# afternoon before this guard existed.
	if _entered:
		push_error("proto_drive re-entered: an assertion above threw. " \
			+ "Scroll up to the first SCRIPT ERROR.")
		_failed += 1
		_report()
		return true
	_entered = true
	print("SENTINEL — prototype loop drive\n")

	var start_mass: float = scene.mass.mass
	var start_scale: float = scene.mass.display_scale()
	_ok("starts with configured mass", start_mass > 0.0, "%.0f" % start_mass)
	_ok("debris is on the map", scene.debris.size() > 0,
		"%d pieces (%d large)" % [scene.debris.size(),
			scene.debris.filter(func(d): return d.large).size()])

	# --- collection is an ORDER now, not something the drone decides ---------
	# The drone used to fly to the nearest piece whenever it was idle, which
	# meant the mass economy ran itself. This half of the check is the half
	# that would silently stop meaning anything if auto-collect came back.
	for i in int(60.0 / DT):
		scene.step(DT)
	_ok("the drone does NOT collect unasked",
		is_equal_approx(scene.mass.mass, start_mass)
			and scene.drone_state == "idle",
		"%.0f mass unchanged after 60s of nobody ordering anything"
			% scene.mass.mass)

	# Order it at a piece, the way a tap does.
	var piece := -1
	for i in scene.debris.size():
		if not scene.debris[i].taken and not scene.debris[i].large:
			piece = i
			break
	_ok("there is a loose piece to send it at", piece >= 0, "index %d" % piece)
	scene.drone_target = piece
	scene.drone_state = "outbound"

	var t := 0.0
	while t < 90.0 and scene.mass.mass <= start_mass:
		scene.step(DT)
		t += DT
	_ok("ordered, it collects and mass grows", scene.mass.mass > start_mass,
		"%.0f -> %.0f after %.0fs" % [start_mass, scene.mass.mass, t])

	# And it goes back to waiting rather than helping itself to the next one.
	var idle_mass: float = scene.mass.mass
	for i in int(45.0 / DT):
		scene.step(DT)
	_ok("and then it waits for the next order",
		is_equal_approx(scene.mass.mass, idle_mass),
		"%.0f mass, unchanged over another 45s" % scene.mass.mass)

	# Feed it enough to grow. Each order is one piece, so this is a few taps'
	# worth of play compressed into a loop.
	for _p in 6:
		var nxt := -1
		for i in scene.debris.size():
			if not scene.debris[i].taken and not scene.debris[i].large:
				nxt = i
				break
		if nxt < 0:
			break
		scene.drone_target = nxt
		scene.drone_state = "outbound"
		var guard_c := 0.0
		while guard_c < 60.0 and scene.drone_state != "idle":
			scene.step(DT)
			guard_c += DT
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
	# ATTACKERS, not `aliens`. This check used to read aliens.is_empty(), which
	# was the same thing right up until the Hive put two roaming creatures and
	# five plant nests on the map at worldgen. Those are landmarks with hit
	# points: they are meant to be standing there from the first frame, and
	# counting them as an attack made a correctly quiet opening look like a
	# failure.
	var kinds: Array[StringName] = [&"roamer", &"nest"]
	var standing: Array = scene.aliens.filter(
		func(a): return a.get("kind", &"small") in kinds)
	var attackers: int = scene.aliens.size() - standing.size()
	_ok("no attack while only scavenging",
		not scene.waves.is_active() and attackers == 0,
		"%d attackers after %.0fs of play" % [attackers, t + 5.5])
	_ok("but the hive is already on the map", standing.size() > 0,
		"%d roaming, %d plant nests, %d buried patches"
			% [scene.hive.roamers.size(), scene.hive.plants.size(),
				scene.hive.patches.size()])

	# --- the module WALKS: it does not appear where you tapped ---------------
	# The bug this replaces: a tap set module_pos directly, so the module was
	# re-placed rather than moved and read as respawning. The test for "it
	# walks" is that it is measurably PART WAY there after part of the journey.
	var from: Vector2 = scene.module_pos
	var goal := from
	for _t in 60:
		var c := from + Vector2(cos(_t * 0.7), sin(_t * 0.7)) * 22.0
		if scene.field.is_passable(c):
			goal = c
			break
	scene.module_goal = goal
	var trip := from.distance_to(goal)
	scene.step(DT)
	var after_one: float = from.distance_to(scene.module_pos)
	_ok("one step moves it one step, not the whole way",
		after_one > 0.0 and after_one < trip * 0.5,
		"%.2f m of a %.0f m trip in one %.2f s step" % [after_one, trip, DT])
	_ok("and one step is about what its speed promises",
		absf(after_one - scene.tune.module_speed_mps * DT) < 0.05,
		"%.2f m, speed x dt is %.2f"
			% [after_one, scene.tune.module_speed_mps * DT])

	var walk := DT
	while walk < trip / scene.tune.module_speed_mps * 3.0 + 5.0 \
			and scene.module_pos.distance_to(goal) > scene.tune.module_arrive_m:
		scene.step(DT)
		walk += DT
	_ok("but it does arrive", scene.module_pos.distance_to(goal)
			<= scene.tune.module_arrive_m,
		"%.0f m in %.1f s, straight line would be %.1f"
			% [trip, walk, trip / scene.tune.module_speed_mps])
	# It must never end up somewhere it could not have walked to.
	_ok("and it never stands on impassable ground",
		scene.field.is_passable(scene.module_pos), "")

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

	# --- an invisible wall stops the module, and the terrain is untouched ----
	# The unit test proves is_passable says no. This proves the thing that
	# actually matters: the module, walking under its own steering, does not
	# end up inside one.
	var wall_from: Vector2 = scene.module_pos
	var wall_at := wall_from
	for _t in 200:
		var c: Vector2 = wall_from + Vector2(cos(_t * 0.31), sin(_t * 0.31)) * 18.0
		if scene.field.is_passable(c):
			wall_at = c
			break
	var pts: Array = []
	for i in 10:
		var a := TAU * float(i) / 10.0
		pts.append(wall_at + Vector2(cos(a), sin(a)) * 7.0)
	var h_was: float = scene.field.height_at(wall_at)
	scene.field.wall_polygon(PackedVector2Array(pts))
	_ok("the wall changes no ground at all",
		is_equal_approx(scene.field.height_at(wall_at), h_was),
		"%.4f before and after" % h_was)

	scene.module_goal = wall_at
	var push := 0.0
	while push < 40.0:
		scene.step(DT)
		push += DT
	var into: float = scene.module_pos.distance_to(wall_at)
	_ok("and the module cannot walk into it",
		not scene.field.is_walled(scene.module_pos),
		"stopped %.1f m short of the middle of a 7 m wall" % into)
	_ok("it is still standing somewhere legal",
		scene.field.is_passable(scene.module_pos), "")
	# Undo it, or every check after this one is playing on a different map.
	scene.field.blocked.fill(0)

	# --- shots TRAVEL, they do not teleport ----------------------------------
	# A firefight used to be two groups of models standing still while one of
	# them quietly lost. These assertions are about the gap between firing and
	# landing existing at all, and about who pays for it.
	scene.aliens.clear()
	scene.shots.clear()
	scene.built.clear()
	scene.selected.clear()
	var gunner: BuildOption = null
	for cand in scene.options:
		var sp: MachineSpec = scene.spec_for(cand)
		for w in sp.weapons:
			if int(w.family) == MachinePart.Family.RANGED and float(w.range_m) > 6.0:
				gunner = cand
				break
		if gunner != null:
			break
	_ok("there is a ranged machine to test with", gunner != null,
		gunner.display_name if gunner != null else "none in the catalogue")
	if gunner != null:
		var gspec: MachineSpec = scene.spec_for(gunner)
		var reach := 0.0
		for w in gspec.weapons:
			reach = maxf(reach, float(w.range_m))
		var gun_at: Vector2 = scene.module_pos
		scene._field(gunner, gspec, gun_at)
		# Well inside range, and far enough that a 34 m/s bolt needs real
		# frames to cross the gap.
		var mark: Vector2 = gun_at + Vector2(reach * 0.85, 0.0)
		var victim: int = scene._add_alien(mark, 400.0, &"small", 0.0)
		var vi: int = scene._alien_index(victim)
		var vhp: float = scene.aliens[vi].hp

		scene.step(DT)
		_ok("firing puts something in the air",
			scene.shots.size() > 0, "%d shot(s)" % scene.shots.size())
		_ok("and it has NOT hit yet",
			is_equal_approx(scene.aliens[scene._alien_index(victim)].hp, vhp),
			"%.0f hp untouched %.0f m away" % [vhp, reach * 0.85])

		# PIN BOTH OF THEM. Left alone the swarmer walks into contact and kills
		# the Guard inside twenty seconds, and a dead gun fires nothing — which
		# is what made the second half of this block report "0 shots" as though
		# projectiles were broken. Holding the alien at range and the machine
		# at full health makes this a test of the projectile and nothing else.
		var flight := DT
		while flight < 12.0 \
				and is_equal_approx(scene.aliens[scene._alien_index(victim)].hp, vhp):
			_pin(gspec, victim, gun_at, mark)
			scene.step(DT)
			flight += DT
		_ok("the shot arrives and damage lands",
			scene.aliens[scene._alien_index(victim)].hp < vhp,
			"%.0f -> %.0f after %.2fs of flight"
				% [vhp, scene.aliens[scene._alien_index(victim)].hp, flight])
		# The whole point: the gap is measurable, not a rounding error.
		_ok("the flight took real time", flight >= reach * 0.85
				/ scene.tune.shot_speed_ranged_mps * 0.5,
			"%.2fs for %.0f m at %.0f m/s"
				% [flight, reach * 0.85, scene.tune.shot_speed_ranged_mps])

		# A target that dies in flight: the shot must resolve, not linger or
		# crash trying to find an id that is no longer in the array.
		# Wait for the NEXT shot to actually be in the air before killing the
		# target. Clearing and stepping once launched nothing — the gun was
		# still on cooldown — so this check passed while testing nothing.
		scene.shots.clear()
		scene.aliens[scene._alien_index(victim)].hp = 400.0
		var arm := 0.0
		while arm < 20.0 and scene.shots.is_empty():
			_pin(gspec, victim, gun_at, mark)
			scene.step(DT)
			arm += DT
		var launched: int = scene.shots.size()
		_ok("a second shot goes up", launched > 0,
			"%d in the air after %.1fs" % [launched, arm])
		scene.aliens[scene._alien_index(victim)].hp = 0.0
		scene.step(DT)                      # the death sweep removes it
		var spin := 0.0
		while spin < 12.0 and not scene.shots.is_empty():
			_pin(gspec, victim, gun_at, mark)
			scene.step(DT)
			spin += DT
		_ok("a shot whose target dies still resolves",
			scene.shots.is_empty() and launched > 0,
			"%d launched, all resolved in %.2fs" % [launched, spin])

	# --- health bars are information, not decoration -------------------------
	scene.aliens.clear()
	scene.shots.clear()
	scene.fog.begin_frame()
	scene.fog.reveal(scene.module_pos, 40.0)
	var spot: Vector2 = scene.module_pos + Vector2(6.0, 0.0)
	scene._add_alien(spot, 100.0, &"small", 0.0)
	scene._present(DT)
	var bars_full: int = scene._mm_bars.multimesh.visible_instance_count
	scene.aliens[0].hp = 40.0
	scene._present(DT)
	var bars_hurt: int = scene._mm_bars.multimesh.visible_instance_count
	_ok("a healthy swarmer wears no bar", bars_hurt > bars_full,
		"%d bar instances at full health, %d once it is hurt"
			% [bars_full, bars_hurt])
	scene.aliens.clear()
	scene._add_alien(spot, 260.0, &"roamer", 0.0)
	scene._present(DT)
	_ok("but a roamer always does",
		scene._mm_bars.multimesh.visible_instance_count > bars_full,
		"%d instances with one untouched roamer on the map"
			% scene._mm_bars.multimesh.visible_instance_count)
	# Two instances per bar, back and fill, and never half of one.
	_ok("bars go in as back-and-fill pairs",
		scene._mm_bars.multimesh.visible_instance_count % 2 == 0,
		"%d instances" % scene._mm_bars.multimesh.visible_instance_count)

	# A BAR IS WIDER THAN IT IS TALL. This reads the transform back out of the
	# MultiMesh, and it is here because the first version used Basis.scaled(),
	# which scales the basis ROWS — a world-axis scale applied on the left. On
	# the camera's rotated basis that came out standing on end with width and
	# height swapped, as thin ticks nobody could read, and every other
	# assertion about bars passed happily while it did.
	# A BAR IS WIDER THAN IT IS TALL, read off the basis the draw pass uses.
	#
	# Not off the MultiMesh: the headless renderer keeps no instance transforms
	# and hands back identity for every one of them, so a check that read them
	# would pass on a bug and fail on a fix. bar_basis() is the real thing the
	# draw pass calls.
	var face: Basis = scene.camera.global_transform.basis
	var bb: Basis = scene.bar_basis(face, scene.tune.bar_width_m,
		scene.tune.bar_height_m)
	var bw: float = bb.x.length()
	var bh: float = bb.y.length()
	_ok("and a bar is a bar shape, not a tick",
		bw > bh * 2.0, "%.2f m wide, %.2f m tall" % [bw, bh])
	_ok("at exactly the width it was configured to be",
		absf(bw - scene.tune.bar_width_m) < 0.01
			and absf(bh - scene.tune.bar_height_m) < 0.01,
		"%.2f x %.2f against a configured %.2f x %.2f"
			% [bw, bh, scene.tune.bar_width_m, scene.tune.bar_height_m])
	# And it faces the camera: the card's own normal points back down the
	# camera's view axis, which is the whole reason the basis comes from there.
	_ok("and it faces the camera",
		absf(bb.z.normalized().dot(face.z)) > 0.999,
		"card normal against the view axis")

	# --- three zoom rungs ----------------------------------------------------
	_ok("there are three of them", scene.tune.camera_zoom_steps.size() == 3,
		"%d rungs" % scene.tune.camera_zoom_steps.size())
	_ok("and the one it starts on is the widest",
		scene.zoom_step == 0
			and is_equal_approx(scene.tune.camera_zoom_steps[0],
				_widest(scene.tune.camera_zoom_steps)),
		"rung 0 is %.2f" % scene.tune.camera_zoom_steps[0])
	var heights: Array[float] = []
	for _z in 3:
		# _ease_zoom, not _present. Settling the tween needs the easing step and
		# nothing else, and a full presentation pass costs a terrain upload, a
		# fog upload and a scenery cull — running 360 of those to watch one
		# float converge took this check from seconds to minutes.
		for i in 200:
			scene._ease_zoom(DT)
		heights.append(scene.camera.position.length())
		scene.cycle_zoom()
	_ok("each rung really moves the camera",
		heights[0] > heights[1] and heights[1] > heights[2],
		"%.0f m -> %.0f m -> %.0f m from the rig"
			% [heights[0], heights[1], heights[2]])
	_ok("and cycling wraps back to the widest", scene.zoom_step == 0,
		"three presses returns to rung 0")

	# AND NONE OF THEM PUT THE CAMERA UNDER THE MAP. The rig sat at y = 0 while
	# the biodome floor is around y = 21 — invisible at the shipped height of
	# 48 m, and fatal at the closest rung, which puts the camera at 18 m. The
	# frame came back solid black with no error anywhere.
	var worst := 1.0e9
	var worst_rung := 0
	for z in 3:
		scene.zoom_step = z
		for i in 200:
			scene._ease_zoom(DT)
		var clear: float = scene.camera_clearance()
		if clear < worst:
			worst = clear
			worst_rung = z
	_ok("and none of them put the camera under the map", worst > 4.0,
		"%.1f m of clearance at the worst rung (%d)" % [worst, worst_rung])
	scene.zoom_step = 0

	# --- the four effects ----------------------------------------------------
	# Each one fixes something the game could not say. These check that it
	# actually says it, and — for the two with teeth — that it does not change
	# anything it was not supposed to.
	print("")
	scene.aliens.clear()
	scene.shots.clear()
	scene.built.clear()
	scene.fog.begin_frame()
	scene.fog.reveal(scene.module_pos, 50.0)
	var spot2: Vector2 = scene.module_pos + Vector2(8.0, 0.0)
	var vic: int = scene._add_alien(spot2, 100.0, &"small", 0.0)

	# HIT FLASH
	var vi2: int = scene._alien_index(vic)
	var cold: Color = scene._alien_tint(scene.aliens[vi2])
	scene._land(spot2, vic, 10.0, 0.0)
	var hot: Color = scene._alien_tint(scene.aliens[scene._alien_index(vic)])
	# TOWARD WHITE, not brighter. The alien's own colour is already 1.0 in red,
	# so HSV value cannot rise and the first version of this check compared
	# 1.00 to 1.00 and failed a working effect. What a flash does is wash the
	# colour OUT, which is a drop in saturation.
	_ok("a hit lights the thing that was hit", hot.s < cold.s - 0.1,
		"saturation %.2f -> %.2f" % [cold.s, hot.s])
	for i in int(scene.fx.flash_s / DT) + 4:
		scene.step(DT)
	_ok("and it goes out again",
		absf(scene._alien_tint(scene.aliens[scene._alien_index(vic)]).s
			- cold.s) < 0.01,
		"back to %.2f after %.2f s"
			% [scene._alien_tint(scene.aliens[scene._alien_index(vic)]).s,
				scene.fx.flash_s])

	# DEATH, and the part with teeth: a corpse must not be a target, must not
	# be damageable, and must not be counted.
	var live_before: int = scene._live_hostiles()
	scene.aliens[scene._alien_index(vic)].hp = 0.0
	scene.step(DT)
	var idx: int = scene._alien_index(vic)
	_ok("a dead thing does not vanish instantly", idx >= 0,
		"still on the map %.2f s in" % DT)
	_ok("but it is not counted as a hostile any more",
		scene._live_hostiles() == live_before - 1,
		"%d live, was %d" % [scene._live_hostiles(), live_before])
	_ok("and nothing will shoot at it",
		scene._nearest_alien(spot2, 40.0) < 0
			and scene._nearest_alien_in_band(spot2, 0.0, 40.0) < 0,
		"no target found where a corpse is")
	var corpse_hp: float = scene.aliens[idx].hp
	scene._land(spot2, vic, 50.0, 6.0)
	_ok("and it cannot be damaged further",
		is_equal_approx(scene.aliens[scene._alien_index(vic)].hp, corpse_hp),
		"%.0f hp, unchanged by a shell on top of it" % corpse_hp)
	for i in 3:
		scene.step(DT)
	_ok("it shrinks as it goes",
		scene._death_scale(scene.aliens[scene._alien_index(vic)]) < 1.0,
		"scale %.2f" % scene._death_scale(
			scene.aliens[scene._alien_index(vic)]))
	var gone := 0.0
	while gone < scene.fx.death_s * 3.0 + 1.0 \
			and scene._alien_index(vic) >= 0:
		scene.step(DT)
		gone += DT
	_ok("and then it is gone", scene._alien_index(vic) < 0,
		"cleared after %.2f s, death_s is %.2f" % [gone, scene.fx.death_s])

	# CAMERA SHAKE.
	#
	# SETTLE EVERYTHING ELSE FIRST. The camera is also being moved by the zoom
	# tween and by the leash chasing the module, and the first version of this
	# check measured all three at once: it reported a 0.85 m shake as 14.30 m
	# and never saw it settle. A test of one thing has to hold the other two
	# still.
	scene.zoom_step = 0
	scene.module_goal = scene.module_pos
	for i in 400:
		scene._ease_zoom(DT)
		scene._present(DT)
	var rig_was: Vector3 = scene.rig.position
	var cam_was: Vector3 = scene.camera.position
	scene._kick(Vector2(scene.rig.position.x, scene.rig.position.z), 60.0)
	scene._present(DT)
	_ok("an impact moves the camera",
		scene.camera.position.distance_to(cam_was) > 0.01,
		"%.2f m" % scene.camera.position.distance_to(cam_was))
	# THE ONE THAT MATTERS. The rig is the view centre — the pan, the leash and
	# the minimap all read it. Shaking THAT would drag the world's idea of
	# where the player is looking.
	_ok("but not the view centre",
		scene.rig.position.distance_to(rig_was) < 0.001,
		"the rig did not move, so the pan and the leash are untouched")
	var shake_settle := 0.0
	while shake_settle < 6.0 and scene.camera.position.distance_to(cam_was) > 0.005:
		scene._present(DT)
		shake_settle += DT
	_ok("and it settles back exactly where it was",
		scene.camera.position.distance_to(cam_was) < 0.005,
		"%.4f m off after %.1f s" % [
			scene.camera.position.distance_to(cam_was), shake_settle])
	# An explosion on the far side of the map must not shake anything.
	# Drain the last of the previous shake first: the loop above stops at
	# 5 mm, and 5 mm of leftover wobble is bigger than the nothing this check
	# is looking for.
	for i in 90:
		scene._present(DT)
	var far_off: Vector2 = Vector2(scene.rig.position.x, scene.rig.position.z) \
		+ Vector2(scene.fx.shake_range_m + 30.0, 0.0)
	var before_far: Vector3 = scene.camera.position
	scene._kick(far_off, 200.0)
	scene._present(DT)
	_ok("something off screen shakes nothing",
		scene.camera.position.distance_to(before_far) < 0.005,
		"%.0f m away, range is %.0f"
			% [scene.fx.shake_range_m + 30.0, scene.fx.shake_range_m])

	# EMERGE RING
	scene.aliens.clear()
	var marks_quiet: int = scene._markers().size()
	scene._add_alien(spot2, 60.0, &"small")     # default emerge, still climbing
	var marks_emerging: int = scene._markers().size()
	_ok("something climbing out draws a ring",
		marks_emerging >= marks_quiet + scene.fx.ring_dots,
		"%d markers -> %d, ring is %d dots"
			% [marks_quiet, marks_emerging, scene.fx.ring_dots])
	while not scene.aliens.is_empty() \
			and float(scene.aliens[0].get("emerge", 0.0)) > 0.0:
		scene.step(DT)
	_ok("and the ring goes when it is up",
		scene._markers().size() == marks_quiet,
		"%d markers once it has surfaced" % scene._markers().size())

	# VINE WIND — a material setting, so what is checkable here is that it is
	# on the things that grew and off everything else.
	_ok("the wind is on the things that grew",
		ModelLibrary.sways("flora_tendril") and ModelLibrary.sways("flora_brain"),
		"flora_* sway")
	_ok("and not on machines, rocks or ruins",
		not ModelLibrary.sways("turret") and not ModelLibrary.sways("rock_spire")
			and not ModelLibrary.sways("alien_ruin"),
		"stone that sways is worse than stone that does not move")

	# --- presentation and instrumentation ------------------------------------
	# Everything above drives step() only. This is the first thing that touches
	# _present(): the scenery MultiMeshes, the fog cull, the convoy bodies and
	# the frame probe. Headless has no renderer, but every one of these is a
	# GDScript path that can throw, and a phone build that crashes on frame one
	# is not something to discover on the phone.
	_ok("the biodome grew", scene._scenery_total > 0,
		"%d props on the map" % scene._scenery_total)
	# RELATIVE, not absolute. This read probe.frames == 30 and broke the day a
	# check above it started calling _present for its own reasons. What it
	# means is "thirty more frames went through without throwing".
	var frames_before: int = scene.probe.frames
	for i in 30:
		scene._present(DT)
	_ok("presentation runs", scene.probe.frames - frames_before == 30,
		"%d frames sampled" % (scene.probe.frames - frames_before))
	_ok("scenery is culled to what has been explored",
		scene._scenery_drawn > 0 and scene._scenery_drawn < scene._scenery_total,
		"%d of %d drawn" % [scene._scenery_drawn, scene._scenery_total])

	# --- the camera follows on a leash, it is not welded on ------------------
	# Welding the rig to the module is what walking first did, and it made the
	# pan gesture useless: the player dragged the view somewhere and the next
	# simulation step dragged it straight back. A nudge smaller than the leash
	# has to survive; a module that walks out of the leash has to be chased.
	scene.module_goal = scene.module_pos
	var nudge: float = scene.tune.camera_leash_m * 0.5
	scene.rig.position += Vector3(nudge, 0.0, 0.0)
	var panned_to: Vector3 = scene.rig.position
	for i in 20:
		scene._present(DT)
	_ok("a pan inside the leash is left alone",
		scene.rig.position.distance_to(panned_to) < 0.01,
		"held %.1f m off centre" % nudge)

	# Now put the module well outside it and let the rig chase.
	var far: Vector2 = scene.module_pos
	for _t in 400:
		var c: Vector2 = scene.module_pos + Vector2(cos(_t * 0.37), sin(_t * 0.37)) \
			* (scene.tune.camera_leash_m * 2.5)
		if scene.field.is_passable(c):
			far = c
			break
	scene.module_goal = far
	var chase := 0.0
	while chase < 30.0 and scene.module_pos.distance_to(far) \
			> scene.tune.module_arrive_m:
		scene.step(DT)
		scene._present(DT)
		chase += DT
	var lag: float = scene.module_pos.distance_to(
		Vector2(scene.rig.position.x, scene.rig.position.z))
	# The bound is NOT the leash. The follow is a spring pulling at
	# slack * camera_follow, so a module walking flat out settles where that
	# pull equals its speed — leash + speed/follow, not leash. Asserting the
	# leash alone failed by exactly that 2.6 m, which is the spring working,
	# not the leash breaking.
	var settle: float = scene.tune.module_speed_mps / scene.tune.camera_follow
	_ok("but the module is never allowed off the leash",
		lag <= scene.tune.camera_leash_m + settle + 0.5,
		"%.1f m from the view centre: %.0f leash + %.1f the spring gives back"
			% [lag, scene.tune.camera_leash_m, settle])

	var before_units: int = scene.built.size()
	scene._stress()
	# COUNTED AT INJECTION. Measuring after ten steps counted what SURVIVED
	# ten steps, and now that twelve machines put real shots in the air that
	# is a smaller number every time they get better — a check that fails
	# because the game improved is a check measuring the wrong thing.
	var loaded_units: int = scene.built.size()
	var loaded_hostiles: int = scene.aliens.size()
	for i in 10:
		scene.step(DT)
		scene._present(DT)
	_ok("the test load actually loads the frame",
		loaded_units > before_units and loaded_hostiles >= 60,
		"%d machines, %d hostiles injected; %d hostiles left ten steps later"
			% [loaded_units, loaded_hostiles, scene.aliens.size()])
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

	_report()
	return true    # done — end the main loop


func _report() -> void:
	print("")
	if _failed == 0:
		print("LOOP TURNS — collect, grow, build, commit, hold, bank.")
	else:
		print("%d CHECK(S) FAILED" % _failed)
	quit(_failed)


## Mass lying on the ground waiting for the drone.
func _wreck_mass(s: Node3D) -> float:
	var total := 0.0
	for w in s.wrecks:
		total += w.mass
	return total


## Hold the gunner and its target exactly where they were put.
##
## BOTH POSITIONS, not just the hit points. Left to itself the machine walks to
## its escort station, which sits at almost exactly the radius this test puts
## the alien at — so the two ended up on top of each other, every shot launched
## and landed inside a single step, and `shots` was empty every time the loop
## looked at it. The projectiles were working perfectly; the test had simply
## arranged for the gap to be zero.
func _pin(gspec: MachineSpec, victim: int, gun_at: Vector2, at: Vector2) -> void:
	if not scene.built.is_empty():
		scene.built[0].hp = gspec.max_hp
		scene.built[0].pos = gun_at
	var i: int = scene._alien_index(victim)
	if i >= 0:
		scene.aliens[i].pos = at


## PackedFloat32Array has no max(). It is not an Array, and reaching for the
## Array method compiles fine and dies at runtime.
func _widest(steps: PackedFloat32Array) -> float:
	var m := 0.0
	for z in steps:
		m = maxf(m, z)
	return m


func _ok(name: String, cond: bool, detail: String) -> void:
	if not cond:
		_failed += 1
	print("  %s  %s  %s" % ["PASS" if cond else "FAIL", name.rpad(40), detail])
