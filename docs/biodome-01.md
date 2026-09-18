# Biodome 01 — the drowned garden

> `godot --headless --path . --script tools/build_biodome.gd` authors the map,
> checks it, and exports a preview. 14 checks.
> `~/.cache/blender-venv/bin/python tools/blender/biodome_preview.py build/biodome models build/biodome`
> renders what Godot actually built.

The brief was a bioluminescent-cavern painting: glowing teal channels winding
through a dark valley, pale ribbed arches growing out of the floor, thickets of
luminous pods, purple lobed masses, dark rock.

**What this is not.** That painting has millions of implied polygons,
volumetric god-rays and wall-to-wall detail. This is the mobile reading of it —
silhouette, palette and glow at a few hundred triangles a prop, on a phone that
has to hold 60fps under thermal throttle. It reads as the same place. It is not
the same image, and no amount of scatter tuning will make it one.

## The map

150 × 112 m, authored as a **seed plus a list of ops** — never a stored
heightfield. CLAUDE.md risk item 3 says a save is the procedural seed plus a
deformation diff, so the maps are authored in exactly that format; if it cannot
express the map we want, we find out now rather than at save/load time.

Every shape on it is made of one primitive: discs stamped along a polyline.

| feature | how | reads as |
|---|---|---|
| rocky ledges | discs at 0.86–0.92, r 11–13 | valley walls |
| glowing channels | a wide shallow **bank** at 0.32, then a narrow deep cut at 0.09–0.17 | impassable liquid with a boggy shore |
| the pale path | discs at 0.74, r 3.6 | the one route always open |
| landing clearing | one disc at 0.56, r 14 | flat, dry, buildable |
| basins | discs at 0.33–0.34, r 13–15 | rough ground that slows without stopping |

**The bank pass matters and the order matters.** A single deep stamp goes from
ridge to water in about four metres, which leaves almost no ground in the rough
band and turns every pool into a kerb. Banking first and cutting inside it
gives a shoreline units can be caught on — 12.9% of the map is rough, against
3.3% before.

**Channels are ~4 m wide, not 7.** The first pass used seven-metre radii and
the plan view came back as three ponds. At this map size a channel has to be
about four metres across before it reads as something that wound its way here.

Current shape: 10.1% impassable liquid, 12.9% rough shoreline, 18.5% ledge, and
a 116 m path that is passable end to end.

## The dressing

Six props, scattered from a seed. Same reasoning as the map: a saved list of
457 transforms is the megabytes-per-save mistake that rule exists to prevent.

| prop | tris | count | placed as |
|---|---|---|---|
| `flora_arch` | 1058 | 16 | landmarks, 6 thickets, scale 1.3–2.4 |
| `flora_brain` | 590 | 11 | purple lobed masses on high ground |
| `flora_tendril` | 524 | 120 | mats along the waterline |
| `flora_coral` | 310 | 95 | branching fans in the shallows |
| `flora_pods` | 368 | 150 | glowing clutter everywhere |
| `rock_spire` | 86 | 70 | the only thing here that is not alive |

**Thickets, not a lawn.** Growth in a cavern crowds where the light and the
water are and leaves bare ground between. Each entry picks N cluster centres
first and grows everything within `cluster_radius_m` of one — a uniform scatter
at these counts reads as a mown field with ornaments on it.

**The waterline is deliberately populated.** Tendrils, coral and pods have a
`height_min` just *below* the 0.26 waterline, so they stand ankle-deep in the
shallows the way the reference does. Nothing is allowed out into deep water
(below 0.19), and that is checked.

**Props follow the slope only partway** — `follow_slope` is 0.85 for rock and
0.10–0.55 for everything living, because a plant grows toward the light and
should not lie down flat on a hillside.

## Performance — measured nowhere yet

This is the part to be suspicious of. 457 props is about 165k triangles if
every one were submitted at once, so two things keep it down:

- **Fog culling.** Only *explored* ground submits its scenery. Geology is
  remembered, unlike live contacts, so an arch you walked past stays on the map
  — but one you have never seen is not drawn. Early game submits a handful.
- **Spatial buckets.** Godot frustum-culls a MultiMesh as a single object, so
  one instancer per prop kind would submit every prop on the map whichever way
  the camera pointed. Scenery is bucketed into 48 m squares instead, which
  costs a few more draw calls and lets the frustum do its job.
- **Shadows only where they are missed.** Every instance that casts a shadow is
  drawn again into the atlas. Arches, brains and spires cast; tendrils, coral
  and pods do not.

**Spike A measured the terrain unlit and undressed.** Those numbers — 13.60 ms
worst minute on a Galaxy A54, p95 landing exactly on 16.67 ms with zero margin
— do not cover any of this, and they did not cover the lighting rig either.
The honest position is that the phone number is unknown and needs re-running
before anything here is trusted.

## Looking at it

`biodome_preview.py` renders the *same* heightfield, the *same* prop transforms
and the *same* palette that Godot writes. If the render disagrees with the
game, the render is wrong. Three views: `_path` (roughly the RTS camera,
looking down the pale path), `_valley` (where the channels braid), `_plan` (the
whole map orthographic).

Two mistakes the first render caught that no headless check could have:

1. **An emissive plane at the waterline** cut a straight edge across the map
   wherever the plane ended. The glow is baked per-vertex now, with the same
   shoreline feather the shader applies.
2. **The arches read as smooth grey tubes.** Three struts 0.55 m apart with a
   0.10 rib merged into one shape at RTS distance. They are 1.05 m apart with a
   0.26 rib now, and the ocelli sit *on* the outer struts instead of floating
   inside where the ribs hid them.

## The hive: four ways to wake it, four ways to stop it

The map starts quiet. **Two** large creatures roam it in the open and
everything else is underground. Waking it is always something the player did,
and every source has an **off switch they can reach**:

| # | What wakes it | What stops it | Who owns it |
|---|---|---|---|
| 1 | Digging a large debris piece | the piece comes free | `WaveDirector` |
| 2 | Walking near an alien plant | the plant is destroyed | `Hive` |
| 3 | Stepping on a burrow patch | one group, then spent | `Hive` |
| 4 | Approaching a roaming creature | the creature is killed | `Hive` |

The off switch is the whole design, not a nicety. A source that cannot be
switched off is a timer wearing a costume: the player cannot answer it, only
outlast it, and the brief is explicit that waves on a clock is what v1 got
wrong. `tools/hive_check.gd` therefore spends most of its 22 assertions on the
*stopping*, not on the firing — that a dead plant stays dead while the player
stands on its corpse, that a spent patch gives nothing for another minute,
that a killed creature's escorts stop coming.

Placement rules worth keeping: the two roamers start at least two territories
apart (67 m on the shipped seed, for a 26 m territory) so meeting one is a
decision about which way to go rather than a patrol you are inside of; nests
are chosen from the dressing's **own** `flora_brain` placements, so a nest is
always a plant you can see and walk up to, never an invisible box that happens
to sit near one; patches are spaced 18 m apart so one step cannot trip three;
and nothing at all is placed within 22 m of the landing site.

### The things that were nearly wrong

**The trigger test counted nothing, and passed.** The debris check read

```gdscript
var spawns := 0
w.spawn_due.connect(func(_n, _i): spawns += 1)
```

GDScript lambdas capture by **value**, so the lambda incremented a copy and the
outer `spawns` stayed at zero forever. All three debris assertions were
comparing 0 to 0 and two of them were phrased so that passed. A one-element
`Array`, captured by reference, is the fix — which is the idiom
`tools/proto_drive.gd` was already using for its mass counter.

**And once it counted, the window was wrong.** The check asked for two groups
in 30 s when `interval_s` is 45: the first group lands at 11 s and the second
at 56, so the window could never have held two. Windows in that check are
written in **intervals** now, not in seconds.

That leaves a real balance observation, recorded rather than acted on because
it is a feel question: a large piece takes `large_free_s` = 26 s to free and
the wave interval is 45 s, so **a large dig delivers exactly one group**. The
ramp in `WaveDirector.group_size()` never gets a second group to act on. The
check now asserts only what must be true for the trigger to mean anything —
that the first group arrives *before* the dig finishes, or the fight would
begin after the prize was already won.

**`_open_point()` sampled cells and fed them to a metres API.** `is_passable()`
takes world metres; the sampler drew from `[4, cells_x - 4]`. Identical today
because `cell_size_m` is 1.0, and it would have stayed invisible until the day
that changed, when every roamer, nest and patch would have bunched into one
corner of the map.

**The Hive holds ids, not indices.** Dead aliens are removed from the scene's
flat `aliens` array, which shifts every index after them. A roamer holding
index 12 would silently start reading somebody else's hit points the first
time anything in front of it died — and the symptom would be escorts that stop
for no reason, which is indistinguishable from the feature working.

## The module walks

Tapping the ground used to set `module_pos` directly. The module was not
moving, it was being **re-placed**, which is exactly why it read as respawning
wherever you tapped. A tap now sets `module_goal` and `_walk_module` drives
there at `module_speed_mps`, sliding along a blocked edge rather than stopping
dead — the map is full of rims that clip a straight line by half a metre, and a
body that halts on one reads as broken.

The cost is the point: the module can now be caught out of position, which is
what a body carrying your mass is for.

### The camera was welded to it

The first version of the walk set `rig.position` — and `rig` is the **camera**
pivot, not the module. The module's mesh is placed separately in `_present`.
Two things were wrong with that. `step()` is documented sim-only and a camera
is presentation; and re-centring every frame the module moved meant the pan
gesture was wiped out on the next simulation step, so the player could not look
anywhere while walking.

`_follow_module` does it in presentation instead, on a **leash**: inside
`camera_leash_m` of the view centre a pan is left exactly where the player put
it, and past it the rig eases along. The bound on how far the module can get is
not the leash — the follow is a spring pulling at `slack * camera_follow`, so a
module walking flat out settles where that pull equals its speed, at
`leash + speed / follow`. Asserting the leash alone failed by exactly that
2.6 m, which is the spring working, not the leash breaking.

## Three zoom rungs, a pinch and a button

The framing the game shipped with is now rung 0, the widest of three. Each rung
is a **multiplier on `camera_offset`**, not its own offset, so the camera keeps
its seventy-degree pitch and simply comes in: a zoom that also changes the
angle reads as cutting to a different camera rather than moving closer.
Measured from the rig: **51 m → 32 m → 19 m**.

Three ways in: the **ZOOM** button (first in the right-hand column, before
TRENCH — it is a control the player reaches for constantly, not instrumentation
like PERF, and it reports which rung it is *on* rather than which one it will
go to), a **two-finger pinch**, and the mouse wheel, which exists only so the
rungs can be tested without a touchscreen.

The pinch is continuous and **settles on the nearest rung when the fingers
lift**, so the gesture feels live but the game still has three named levels and
the next press of the button continues from a known one. Fingers apart means
closer, so the ratio goes on the *bottom* of the multiplier.

### And the closest rung rendered solid black

The camera rig sat at **y = 0** while the biodome floor is around **y = 21**.
At the shipped camera height of 48 m that is invisible — the camera clears the
ground by 27 m either way. The closest rung puts it at 18 m, which is three
metres *underneath the map*, and the frame comes back black with no error
anywhere. The middle rung survived but pushed the module to the top of the
screen, because `look_at` was aiming at a point below the terrain.

The rig rides the ground now, re-seated on every `_frame_camera()` including
after a pan, since panning moves it over terrain of a different height. There
is a `camera_clearance()` and a check that asserts it is positive at every
rung: a camera under the map is a black screen, and a black screen is not
something any assertion about zoom multipliers would ever have caught.

Two things the pinch dragged in with it:

- **A second finger has to cancel the first one's gesture.** Without that, the
  hand starting a pinch also panned the map and, on lifting, issued a move
  order to wherever the first finger happened to be. And when a pinch ends with
  one finger still down, panning does *not* resume with it — the hand is
  halfway through a gesture and the map would jump.
- **Both the pan and the leash scale with the zoom.** A drag has to move the
  ground under the thumb by the same distance whatever the camera height, or
  panning zoomed in flings the map off the screen; and `camera_leash_m` is
  really "how far off centre may the module get before it leaves the screen",
  which is a smaller distance the closer the camera is.

## Shots travel

Damage used to land the instant a cooldown came up, which made a firefight two
groups of models standing still while one of them quietly lost. Weapons now put
a **projectile** in the air: a flat bolt for direct fire, a slower arcing shell
for artillery, drawn unlit through their own MultiMesh so a tracer the moon
fails to catch is not a tracer nobody sees.

- **Melee gets no projectile.** A flight time on a contact weapon means a swing
  that connects with something that has already walked away.
- **A shot carries its target's ID, never its index.** Aliens leave the array
  from the middle constantly; an index-carrying shot would arrive at whoever
  had shuffled into that slot.
- **A shot re-aims while its target lives**, so a bolt tracks a running
  swarmer. When the target dies in flight the shot keeps going to where it was
  aimed: a shell still lands and still splashes, a direct-fire bolt simply
  misses. That miss is the price of the travel time being real.
- **Over `shot_cap` the shot still hits**, it is just not drawn travelling.
  Dropping the damage instead would make a big fight quietly weaker than a
  small one, which is the sort of thing nobody finds for months.

### The test had arranged for the gap to be zero

The projectile checks reported "0 shots in the air" and looked like a broken
feature. The projectiles were fine. The test placed its target at
`reach × 0.85` from the module — and the gunner, left to itself, walks to its
**escort station**, which sits at almost exactly that radius. The two ended up
on top of each other, every shot launched and landed inside a single `step()`,
and `shots` was empty every time the loop looked at it. The fix was to pin the
gunner's position as well as its hit points.

Two neighbouring checks were quietly measuring the wrong thing for the same
sort of reason. `probe.frames == 30` broke the day a check above it started
calling `_present` for its own purposes, so it counts thirty *more* frames now.
And the TEST LOAD check counted hostiles after ten steps — which, now that
twelve machines put real shots in the air, is a smaller number every time the
game gets better. It counts them at injection.

**And `tools/proto_drive.gd` no longer runs forever.** A `SceneTree._process`
that returns true is what quits the tree, so a script error partway down meant
the function never returned and the tree called it again — the whole suite
restarting from the top, against a half-played scene, forever. It looks exactly
like a hang. There is a re-entry guard now that fails loudly and points at the
first `SCRIPT ERROR`.

## Health bars, and what does not get one

Two MultiMesh instances per bar, a dark back and a coloured fill, unlit, with
depth testing off — at this camera's shallow angle a bar without that is
swallowed by the model it floats over. The fill is anchored **left** rather than
centred, or a bar drains from both ends at once and reads as shrinking instead
of emptying. They go in as a pair or not at all: half a bar is worse than none.

**Not a bar over everything.** Seventy swarmers wearing full green bars is a
hedge, not information. Things the player makes decisions about — machines, the
module, the roamers and the plant nests — always carry one; a small alien earns
one by being hurt. The list is `ProtoConfig.bar_always_for`, so that judgement
is a data change.

Friendly bars run green → amber → red. Hostile bars run the other way, because
a nearly-dead hostile is *good* news and should be the colour the eye goes to.

Aliens record `hp_max` at birth. A bar needs a denominator, and a roamer, a
nest and a swarmer are all "an alien" with wildly different ones — reading it
back off the config at draw time would put the kind-to-config mapping in two
places.

### Two things about them that only a rendered frame could say

**They drew nothing at all, and every check passed.** The first version used a
`TRANSPARENCY_ALPHA` material with `no_depth_test` — the reasoning being that a
bar sits *on top of* the thing it describes, and at this camera's shallow angle
it would otherwise be swallowed by the model it floats over. It submitted
perfectly: right AABB, right transforms, `visible_instance_count` set, no error
anywhere. It rendered nothing on the Mobile renderer. Every flag in that
material was one the rest of the project uses nowhere else, and none of them
were load-bearing. They are plain opaque unshaded now, and clear their owners
by floating higher instead. This is the third time in this project that a
feature which passed every assertion turned out to be invisible, and it is why
`tools/screenshot.sh` exists.

**And then they were all the same pale mint.** Bars are unshaded albedo, so
they go through the tonemapper and the ink pass untouched by any light, and the
HUD's own colours came out washed to near-white at every fraction — a ramp that
cannot be read is not a ramp. The bar palette is roughly half the value of the
HUD's, which is what survives as a colour.

### The frame had to be made to contain a fight

`tools/screenshot.sh` takes a `fight` argument now. Two reasons the obvious
version of it was useless: the opening state has no machines and no hostiles at
all, and `reveal` does not help because it overrides the *terrain shader's* fog
map while bars and tracers are gated on `fog.is_visible()` in GDScript.
`_stress` fixes both. But `_stress` spawns hostiles on a 46–60 m ring, which is
outside every machine's range — so the first "combat" frame was two armies
standing still looking at each other, with not one tracer in it. The flag pulls
them in to 11 m.

## The drone waits to be told

It used to fly to the nearest piece whenever it was idle, which meant the mass
economy ran itself and the player watched it happen. **Collecting is an order
now**: tap a piece — any piece, wreck or small debris or a stuck one, not just
the one that starts a fight. What the drone does unasked is keep station on the
module.

The panel that used to hide when the drone was idle is now always visible and
says *"tap a piece to collect it"*. Idle is the drone's resting state rather
than a half-second between jobs it found for itself, and a panel that vanishes
reads as "the drone is broken" when the truth is "the drone is waiting for
you".

`drone_auto_collect` is off rather than deleted, so the old hands-off economy
can be switched back on and measured against this one.

## The module is slower

6.5 → **3.6 m/s**. At 6.5 the module crossed the 150 m map in 23 seconds, which
is fast enough that being caught out of position never actually happened — and
being catchable is the whole reason it walks instead of teleporting. At 3.6 the
crossing is 42 seconds and deciding where to stand is a real commitment.

## Not built

- **Nothing is deformable but the ground.** Props do not react to a trench dug
  under them, do not block movement, and do not take damage.
- **No canopy, no overhangs, no volumetrics.** The heightmap decision (not
  voxel) rules out the arch you can walk *under* being real geometry as far as
  pathfinding is concerned — an arch is scenery a unit walks through.
- **One biome.** The palette and dressing are resources, so a second biodome is
  a data change, but only this one exists.
- **The terrain still has its red debug line** at the impassable threshold. It
  is a readability aid, not art; `threshold_line_strength = 0` turns it off for
  screenshots.

## Testing it on a phone

```
./tools/phone_build.sh
```

Four steps: assemble a self-contained project folder, import it *as its own
project*, boot it for 240 frames of the real main scene, then zip it. The
middle two are the point — assembling a folder is easy; proving it opens and
runs before it reaches a phone is what saves a day-long round trip.

**It is a project folder, not an APK.** This machine cannot build an APK at
all: `dl.google.com` is blocked by the egress policy, so the Android SDK and
apksigner are unreachable. The tester opens the folder in the Godot 4.7.2
Android editor and presses play.

`tools/export_phone_build.gd` leaves out `spikes/` (a second `project.godot`
inside the first, which the phone would spend a minute importing for nothing),
`tools/`, `docs/`, `tests/` and the old JS prototype, then checks that **every
`res://` reference in every copied file still resolves** — 173 of them. That
check exists because this project has already shipped a commit message claiming
an export preset was included when `.gitignore` had quietly eaten it.

### The frame-time card

`PERF` on the build bar opens it. `FrameProbe` samples from the first frame
whether the panel is open or not, because the numbers have to cover the whole
session rather than the part after the tester remembered to look.

Criteria, fixed in `frame_probe.gd` **before the build ever ran on a device**:

| | budget | why |
|---|---|---|
| p95 frame time | ≤ 16.67 ms | 60fps |
| worst full minute | ≤ 16.67 ms mean | the number a player feels in a long fight |
| thermal drift | ≤ 1.25× | last minute against the first; a cold-phone number is not a number |

No verdict is given under two minutes of play — a reading off thirty seconds of
a cold device is worse than no reading.

**Draw calls, primitives and VRAM are reported, not judged.** There is no
defensible budget for them on this device that is not a guess, and inventing
one would turn a diagnostic into a criterion nobody can argue with.

`TEST LOAD` jams twelve of the heaviest machines and sixty hostiles onto the
field and opens the fog, so the worst case can be measured in a minute rather
than waited for. It injects mass from nowhere, which the conservation rule
forbids — it says so on screen. It is the only thing in the build that breaks
that rule, and it is instrumentation, not a game action.

## Surface quality

**There are no textures in this project.** No image files, no UVs on any mesh —
`tools/quality_check.gd` asserts that as its first check, so the day one is
added, everything below stops claiming to be the whole story. "Higher quality"
therefore cannot mean a bigger bitmap. It means three other things.

### 1. Procedural surface in the terrain shader

| | what it does |
|---|---|
| detail bump | one octave of noise, sampled twice for a gradient, perturbing the normal. Not an fbm — this runs over most of the screen and a full fbm here would cost more than everything else the fragment does put together. |
| distance fade | past `detail_fade_m` the two extra taps are **skipped entirely**, so most of the screen never pays. It also stops distant ground shimmering. |
| macro variation | one very low-frequency colour drift, so a hundred square metres of ground is not one flat material with grain on it. |
| striation | horizontal bedding on steep faces. The cheapest thing that makes a cliff read as rock rather than a grey ramp. |

Two bugs fixed on the way:

- **The noise hash used `sin()`.** Fine on a desktop GPU; on mobile the compiler
  is free to evaluate it at mediump, where `sin` of a large argument loses its
  low bits and the "noise" collapses into repeating stripes. Replaced with a
  pure multiply-add hash that is stable at any precision.
- **Slope was measured in view space.** `NORMAL` in `fragment()` is view space
  in Godot, so `n.y` was asking "does this face the camera's up", not "does
  this face the sky". With a near-top-down RTS camera the two are close enough
  that the cliff colouring looked right, which is exactly why it survived. The
  world normal is now carried from the vertex stage as a varying.

### 2. Baked ambient occlusion in the vertex channel

`tools/blender/_ao.py` ray-casts each vertex against the prop's own mesh — 12
directions from a golden-angle spiral, not a random generator, so rebuilding
never changes the result — and writes `1 - occlusion` into `COLOR_0`. Costs no
texture memory, needs no UVs, and survives MultiMesh instancing.

Mean occlusion runs 20–31% per prop, and a bake that produced *no* occlusion
fails the build, because a silently-empty bake looks exactly like a flat model.
Glowing material slots are excluded: `COLOR_0` multiplies base colour, and a
light source with occlusion baked into it reads as a dirty bulb.

Rock is now **flat shaded**. Everything else grew, and grown things are smooth;
a stone splinter with smoothed normals reads as a melted candle.

**Godot's glTF importer gets this backwards on these assets.** It enabled
`vertex_color_use_as_albedo` on the *emissive* slots — where the bake is
deliberately white — and left it off on the solid ones, where all the occlusion
is. `ModelLibrary` forces it on for every material, once per model, and
`quality_check.gd` holds that fix in place because the failure mode is
invisible: the model just looks flat.

### 3. Three quality presets

| | MSAA | render scale | terrain detail | shadow atlas |
|---|---|---|---|---|
| High | 4x | 1.00 | on | 2048 |
| Medium | 2x | 1.00 | on | 2048 |
| Low | off (FXAA) | 0.85 | off | 1024 |

Antialiasing matters more here than in a textured game: untextured low-poly art
is nothing *but* silhouette, and every arch strut and coral branch is a thin
high-contrast edge against dark ground. On a tile-based mobile GPU MSAA
resolves in tile memory, so it is cheaper here than the same setting on a
desktop deferred renderer — but it is not free.

**Medium exists to make a failure diagnostic.** It differs from High in exactly
one dimension, so if High misses the frame budget and Medium holds it, the cost
was the antialiasing; if Medium misses too, it is the shader or the prop count.
Two presets would only have told us that the expensive one is expensive.

`QualityRig` runs **after** `LightingRig` and both set the shadow atlas, so the
preset wins — deliberately, because shadow cost is a device decision and
everything else in `LightingConfig` is a look decision. That precedence is
asserted in `quality_check.gd` rather than left as a comment.

### What the Blender preview can and cannot show

The preview renders the same heightfield, prop transforms and palette Godot
writes, and now the same detail bump. It does **not** show MSAA, render scale,
or the shader's macro variation — an attempt to add the last one lifted the
ground's average brightness, and in Cycles the extra bounce washed out every
prop standing on it, so the render came back paler than the game while claiming
to represent it. A colour-balance change is not worth that lie.

**So the antialiasing and the terrain detail are unverified until the phone
build runs.** That is what the three presets are for.

---

# Rebuild: the floor of a ravine

> Replaces the valley described above. Same file, same tools, different map.

The brief became two reference images: a top-down survey map of rounded
plateaus joined by narrow necks, and a landscape phone UI. Three decisions
came out of that, and they were yours, not mine:

1. **Landscape**, matching the UI mockup.
2. **Mass stays the only resource.** The mockup's SHIP PARTS and ESSENCE were
   filler; the conservation rule is untouched.
3. **Islands rather than a continuous valley** — and a *chasm* underneath, not
   space. These are peaks of a very high range, not a floating rock.

## What changed in the map

**The default state of the world is now "no ground here."** The base noise sits
at 0.055, far below the palette's new `void_below` of 0.16, and every island is
something the ops list explicitly raised. Ground below `void_below` is not drawn
at all — `discard` in the fragment shader, not a clip plane, because the edge
follows the heightfield and the cliff face above it has to keep rendering.

`void_below` sits *under* `impassable_below` (0.26) deliberately. Between them
is a rim of real-but-unwalkable ground — the cliff a plateau falls away over,
which is what stops an island looking like a cut-out.

| | |
|---|---|
| ground | 31.2% of the map; the rest is weather |
| walkable | 76.5% of that ground |
| cliff rim | 7.3% of the map, drawn but not walkable |
| necks | 9–10 m of walkable width |

**The route check is the one that matters.** Islands are only a design if you
can get between them, and a neck the falloffs pinched shut would leave half the
map unreachable with nothing else noticing. So the check builds a real
`FlowField` from the far island and asserts every island — and the landing
site — is reachable. It also measures each neck's walkable width, because a
land bridge wide enough to walk around is not a chokepoint.

## The ravine, which replaced the cloud deck

The map used to be peaks standing over weather: one plane under it, one
fragment program, four octaves of scrolling noise cut into billows. The brief
changed to a moonlit mountain ravine, and a scrolling cloud plane cannot be
tuned into that — it is a different object. `RavineWall` builds it in two
pieces:

- **The floor**, a coarse plane under the whole map. The terrain shader
  discards every fragment below `void_below`, so the map is full of holes; this
  is what shows through them, and it is the bottom of the cleft.
- **The ring**, a band outside the map frame that stays at floor height for
  `floor_width_m` and then climbs to the crest. The flat part is the chasm, the
  climb is the wall.

**Why it is not more heightfield.** The traced outline reaches to within three
metres of the map frame on the west side, so there is no room outside it for a
wall; and the terrain grid is what the flow field, the material classifier and
the whole-map detail bake all run over, so widening it to make room costs 1.7x
on every one of them. Nothing walks on the ravine, nothing is placed on it and
nothing paths through it, so it is scenery with its own coarse mesh — about 9k
triangles in two draw calls — and the heightfield is left exactly as it was.

**The rectangle is the point, and so is losing it.** Every row is the map's
rect inflated by `s` in both axes, which is what keeps the chasm a constant
width on all four sides; a circular ring around a 150 x 112 map leaves a 20 m
gap at the middle of the long sides. But carried all the way out that also
leaves four right angles on the skyline, so past the wall foot the ring blends
toward a circle and the foot itself wanders by a low-frequency band. Without
those two the surround reads as a picture frame, which is the first thing the
eye finds at the overhead camera.

It never casts shadows (a caster this size would fill the atlas by itself) and
never receives GI. It is lit by `painted_prop.gdshader` — the same `light()`
the ground and the machines use, because two lighting models in one frame is a
bug this project has already paid for once.

**Three things about it cost a day between them**, all of which look identical
from outside — geometry that is simply not drawn:

1. `painted_prop.gdshader` writes `NORMAL_MAP` inside a branch this material
   never takes, but `NORMAL_MAP_USED` is decided at compile time, so the vertex
   stage reads `TANGENT` on every mesh the shader touches. A SurfaceTool mesh
   has none until `generate_tangents()` is called, and one without renders
   black with no error anywhere.
2. `COLOR_0` is eight bits per channel. Vertex colours converted to linear put
   the cleft floor at 0.002, which quantises to zero.
3. The winding decides both the culling and the normals `generate_normals()`
   produces, so getting it wrong is invisible rather than inside-out.

What finally separated them was setting `emission` and watching the surround
come back magenta while the lit path stayed dark.

## The depth map, and three cast layers

**The third baked map.** A normal map says which way a surface tilts and a
colour map says what it is made of; neither says how far above the floor it is,
and that is the one thing the ground needs in order to cast its own detail onto
itself. A vine lying on the floor and a vine painted on the floor have
identical normals.

Cycles has no displacement bake, so it goes through **POSITION** — the world
coordinate of the high-poly at each low-poly texel — into a float buffer,
because the map is 150 m across and an 8-bit position bake would quantise the
whole thing into six-centimetre steps.

**The bake's scale is measured, not assumed.** The POSITION pass comes back
uniformly *four times too large* in this Blender build: texel centres that
should read x = 37.5, 74.8, 112.0 read 149.95, 299.15, 448.04. Dividing by four
would work today and break silently the day that changes, and a depth map wrong
by a constant looks exactly like a map of taller vines. So the factor is
recovered from the data — every texel's true world X and Y are known in closed
form, because the unwrap is `(x / width, z / depth)` — fitted on both axes
independently and asserted to agree. It reads 4.0000 on both. If the bake is
ever fixed upstream this reads 1.0 and nothing else changes.

**The surface is sampled at the baked position, not the texel's nominal one.**
A cage ray leaves along the low-poly's normal, so on steep ground it lands a
metre or two downhill of the texel it belongs to. Measured against where the
texel nominally is, that lateral slide reads as relief and puts a phantom bank
on every slope; measured against where the ray actually landed, it cancels
exactly. The first version's 99th percentile error was 6.8 m, with strays at
154 m.

**And the range is the relief, not the cage.** Normalised over `CAGE_M` (1.4 m,
which is how far a ray may *travel*) the whole map landed in the bottom 15% of
the 8 bits and came out as speckle. `DEPTH_RANGE_M` is 0.90 — the tallest
species plus a margin — and the fraction that clips is asserted under 2%
(currently 0.98%). Measured: 77% of texels hit, height above ground median
0.028 m, 95th 0.393 m.

**What it buys.** A short march toward the moon across the depth map: at each
step the ray has climbed by the step times the tangent of the sun's elevation,
and if the mat is taller than the ray is high, the fragment is behind it. Six
taps over 0.75 m. Only a height field can put a shadow on the floor *beside* a
vine — bump shading can only turn the vine's own surface away from the light —
and that shadow is most of what says the mat is lying on the ground rather than
printed on it.

It is a **modest** effect at this camera: 3.5% of the frame moves by more than
2/255. That is not a disappointment, it is the scale — at 48 m and ~19 px/m, a
5 cm vine's shadow is about a pixel. `cast_shadow_strength` and
`cast_shadow_reach_m` are the dials.

**Three cast layers, not one.** The canopy is a *cast map* — something overhead
deciding how much light reaches the floor — and there is never only one thing
overhead. Layer 0 is the biodome's roof; 1 and 2 are free, each with its own
texture, scale, drift and scroll speed, and they multiply, so two half-shading
layers leave a quarter the way real occluders stack. Three fixed slots rather
than an array of samplers, because Godot's support for those varies by renderer
and this has to run on Mobile. Each layer costs one fetch and only when its
strength is above zero.

## The canopy, and a light cookie that could not be tested

A cookie is a texture a light looks through — Godot calls the slot
`light_projector`, every other trade calls it a gobo. The design brief says the
player is inside a **sealed biodome** and nothing in the frame has ever said
so: the map reads as open ground under a night sky. A hex lattice of structural
ribs thrown across the floor says "there is a roof on this" with no geometry,
no draw call and no triangle. `tools/make_canopy_cookie.py` generates it.

**The moon cannot carry it.** Verified against the engine's own shader source
in 4.7.2: `projector_rect` appears for spot, omni and area lights and nowhere
for directional. A DirectionalLight3D has no frustum to project through, so a
cookie needs its own light — which is what `CanopyLight` builds.

**And the projector does not work on this machine.** Measured on a bare scene,
not on the map:

| | mean lit value |
|---|---|
| no light | 0.0000 |
| DirectionalLight3D | 0.1368 |
| OmniLight3D | 0.1012 |
| SpotLight3D, no cookie | 0.0418 |
| **SpotLight3D + cookie** | **0.0000** |

Attaching anything to `light_projector` makes the light contribute exactly
zero — on Forward+ and Mobile alike, with an imported texture and with a
runtime `ImageTexture`. It is not the import format, not the renderer and not
the map. It is almost certainly lavapipe, the software Vulkan device this
machine renders with, and it cannot be told apart from an engine bug without a
real GPU. So `canopy_enabled` ships **off**, with `CanopyLight` left correct
and waiting for a device.

**The shipped version is in the shader instead.** `terrain_lit.gdshader`
samples the lattice in world space and multiplies it into the light before
shading — one texture fetch inside a light loop that was already running, and
no second light at all, which is cheaper than the thing it stands in for and is
the only version this machine can prove. The fetch happens in `fragment()` and
reaches `light()` through a varying, which is legal in Godot and is the only
route a per-fragment sample has into the light loop.

That changes what the texture has to be. A projector is thrown through a cone
once, so its border only has to be quiet; a world-space sample **tiles**, so it
has to be seamless — the hex lattice is periodic by construction, the row count
is forced even so the half-cell row offset survives the wrap, and the wrap is
asserted with the same test the rock and scale generators use.

Measured on the frame: median luma 0.209, saturation **0.43** against the
references' 0.46 — the closest this map has come, because the canopy darkens
some ground and the shadows it makes are more saturated than the light it
replaces.

## The two GI options Forward Mobile will run, and what happened to them

Pulled out of the engine binary rather than the docs (which this machine's
egress policy blocks): the complete list of renderer-availability warnings in
4.7.2 says Mobile does **not** run SDFGI, SSAO, SSIL, SSR, volumetric fog,
subsurface scattering, transmittance, auto-exposure, TAA or FSR. What it does
run, beyond the three light nodes and their shadows, is **LightmapGI** and
**ReflectionProbe**.

**LightmapGI cannot be used on this map.** Three independent blockers, all
verified: the terrain mesh is generated at load by `TerrainView`, so there is
nothing in the scene for the editor to bake; it carries no UV2, which a
lightmap needs; and `LightmapGI.bake()` is not exposed to scripting in this
build (only `set_bake_quality` / `get_bake_quality` are), so a headless
pipeline cannot drive it either. All three would have to change together, and
the first one means pre-generating the terrain as a saved mesh resource — which
gives up the procedural-seed-plus-ops rule the map is built on.

**ReflectionProbe works, is correctly placed, and does nothing.**
`WaterProbes` finds the pools by flood-filling the heightfield's own water
mask — four probes, sized to each pool, found rather than authored so that
changing the map moves them. The reasoning for wanting them was sound: the
terrain shader drops the ground to roughness 0.12 and specular 0.6 under the
waterline, so the pools are the only glossy surface on the map.

The frame disagrees. Rendered with and without, back to back, **the pool
changes by a mean of 0.97/255 and a maximum of 5** — half its pixels change by
*something* and 13% by more than 2/255, which is invisible. Two reasons, and
both are properties of this map rather than of the feature: the pools are light
*sources* (`pool_glow` at strength 1.8, through EMISSION) and an emissive
surface swamps anything reflected onto it; and what there is to reflect is a
night sky at luma 0.05 over ground at 0.22, so the probe is faithfully
reflecting almost nothing.

So it ships **off**. Four probes cost four cubemaps of VRAM and six face
renders each at load, and CLAUDE.md's live risk is that the frame budget is
already unmeasured on the current build — that is not a bill to pay for a
change nobody can see. The code stays, because the day this map gets a bright
thing near water, `reflection_enabled` is the whole job.

## Two vine layouts, one generator

`tools/blender/detail_source.py` builds either of two surfaces, chosen by a
fifth argument, and they write to different files so the first is still there
to go back to:

| profile | seeded on | what it is | blend | textures |
|---|---|---|---|---|
| `mat` (default) | the cells the classifier called VINE — a fifth of the map | three tiers of one plant: a root-mat web | `detail_source.blend` | `ground_detail_n/c.png` |
| `vines` | **every drawn cell** | **three species**, each with its own seed, colour and size class | `detail_vines.blend` | `ground_vines_n/c.png` |

```
tools/blender/detail_source.py 2048 1500 650 3          # root mat
tools/blender/detail_source.py 2048 1500 650 3 vines    # whole map
```

One generator with a switch, not a forked copy: everything except *where* the
vines go and *how big* they are is identical, and a second seven-hundred-line
script would be the same file until the day somebody fixed a bug in one of
them. `TerrainView.DETAIL_N` / `DETAIL_C` choose which pair the landmass wears;
the map ships on `vines`.

### The three species

| | seed | colour | radius | length | share of cells |
|---|---|---|---|---|---|
| small | 71 | `#2f6b5f` teal | 22–48 mm | 0.9–2.4 m | 80% |
| middle | 20261 | `#2a5566` blue-teal | 55–95 mm | 2.5–5.5 m | 34% |
| large | 918273 | `#55604f` grey-green | 105–160 mm | 5–11 m | 9% |

**The seeds are independent on purpose.** Three fields sharing one random
stream are not three species, they are one species drawn three times, and the
giveaway is that all three thin out in the same places.

**The large one is bounded by the machines, and the bound is measured.** A mat
with a strand thicker than the drone in it stops being ground the machines
stand on and becomes terrain they are lost in. `smallest_machine_m()` reads the
exported glTF for the drone, guard, bulwark and turret and takes the smallest
of them; the build asserts the largest vine stands under three quarters of it.
Measured at build: **0.38 m against the drone's 0.78 m**. A number typed in the
script instead would go stale the first time a chassis changed and nothing
would notice.

## The vines are splines now

Every vine used to be points and triangles emitted from Python: correct
geometry that nobody could ever edit, because there was nothing in the .blend
to take hold of. They are Blender **curves** now — open either .blend,
tab into `vine_trunks`, and the vines are control points you can move, with the
tube regenerating from them.

One curve datablock per tier, not per vine. `bevel_depth` belongs to the curve
rather than the spline, so each tier carries its own base thickness and the
per-vine swell rides on each control point's `radius`, which multiplies it.
Four thousand curve *objects* is what killed the bake at 66 minutes the first
time round; four is free.

**Half the thickness, and 1.75x the count.** "Smaller" was the ask; sparser was
not, and they are the same change unless you pay for it. Halving a vine's
radius halves the ground it covers per metre of its length, and at the old
count the mat thinned out and the bare floor came through — measured, the baked
map went from 45% near-grey to 49% and the rendered frame's saturation fell
from 0.35 to 0.27. The bevel resolution went *up* at the same time: a 12-sided
tube at 10 cm costs what a 6-sided one at 20 cm did, and now that they are
round the silhouette is worth having.

**The paint moved from vertices to coordinates, and improved.** A curve cannot
hold a colour attribute, so the three variations that used to live in `COLOR_0`
come out of texture coordinates instead — and they are better for it, because a
curve's UV knows where the root and the tip are while a vertex colour only knew
where the vertex was. The along-vine gradient is a ramp on V; the per-vine
jitter is a noise on object coordinates at about two metres, which is spatial
rather than per-object and is the whole reason four thousand vines can share
four datablocks.

## One skin on everything that grew

`tools/make_scale_detail.py` generates a seamless field of overlapping scales —
normal and cavity — and the ground, the vines and the structures all wear it.
That is the point: they are supposed to read as one organism's landscape, and
nothing says so faster than one skin. The machines are deliberately excluded.
They carry their own baked panel detail, and a machine wearing the landscape's
skin would undo the contrast the light grey exists to create.

**Rows lie over rows.** The first version took the tallest dome at each pixel,
which sounds like overlap and is not: two domes of equal height meet at a ridge
halfway between them, so a field of them tessellates into a honeycomb and reads
as bubble wrap. Real scales have a free edge. So it is a painter's order — among
the scales whose footprint covers a pixel, the one from the frontmost row wins
outright and sits a step above what it covers.

**The tiling check was wrong, twice.** "The opposite edges match" fails a map
that tiles perfectly, because the last column sits next to the first column of
the *next* copy and should differ by one ordinary step. Its replacement — "the
wrap step is near the average step" — failed this pattern while it tiled
*exactly*, because most of the image is smooth dome interior and a wrap that
cuts through a row of lips beats the average by a mile. What a seam actually is
is a step much larger than the steps immediately beside it, so the wrap is now
compared to its own neighbours. Both generators use it.

**Props needed UVs, and needed them in metres.** These assets never had any —
the project had no textures when they were written and `COLOR_0` carried
everything. `smart_project` packs each object's islands into 0..1, which means
a 9.3 m arch and an 80 cm pod come out with the same number of UV units across
them, and a tiling texture then makes the arch's scales twelve times the size of
the pod's. So the unwrap is rescaled by a measurement, not a guess: the median
ratio of world length to UV length over every edge, so one UV unit is a fixed
1.2 m of surface. The ground uses 5 m, because it is a floor seen at a distance
and a plant is a small thing close to the same camera.

## Beige, and the measurement that missed it

"Every warm hue in reference 01 put together is 0.38% of the image" was true
and misleading. It was measured over **saturated** pixels, and the reference's
warm content is not saturated: its boulder clusters, its bridge, its coral fans
and its tall pale structure are *beige* — measured properly, 0.7% of area at
rgb(92, 79, 69), saturation 0.24, luma 0.32. Desaturated warm fell straight
through a test that only looked at saturated pixels, and the palette was built
on the conclusion that the reference had no warm in it at all.

So the rock ground material, the arch, the ruins, the coral and the pods are
beige now, and the floor's largest colour drift is toward a warm near-grey.

**The cost, stated plainly:** the rendered frame now measures saturation 0.35
against the references' 0.46. Beige is desaturated by definition, so asking the
map for more of it asks it for less chroma, and the two cannot both go up.
Lowering the ramp and albedo neutralise constants to 0.20 and 0.08 — most of
the way to switching them off — moved it by 0.01, because the baked detail
colour mixes in at 0.62 and is 41% near-grey; it, not those constants, sets the
frame's chroma. The dial that would actually move it is the beige itself.

**The drift goes via grey, not via green**, and that is the whole trick. The
straight line in RGB from this map's teal to a saturated beige passes through
hue 128 at its midpoint, so the first attempt — a strong drift toward `#4e463b`
— turned a third of the map green, which is exactly what it was meant to
remove. A near-neutral warm grey loses the chroma first and picks up the warmth
second: the green band fell from 35% to 8% at a *stronger* weight.

Tuned numerically rather than by baking. `ground_paint` is pure arithmetic over
the heightfield, so a forty-line harness evaluates it over the whole map and
prints the hue histogram in a second; the ten-minute bake only ran once the
numbers were right.

## The survey grid is off

It came from reference 01, which is a VTT battle map — printed with a grid
because a person moves miniatures on it by the square. Nothing in this game
snaps to ten metres, so the grid described a rule that does not exist, and over
a floor that now carries real surface detail it read as graph paper laid over
the art. `grid_spacing_m` and `grid_colour` stay so it can be switched back on
as a debug readout.

## Surface detail, in three places

The floor, the ravine and the machines each needed a fine bump and each needed
a different answer.

**The floor** bakes from modelled geometry, because its detail *is* geometry —
vines, pores, clumps, things with a shape somebody decided. What it was
missing is that the high-detail copy of the ground was the same one-vertex-per-
metre mesh as the bake target, so everything between the vines baked perfectly
flat. It is built at three vertices per metre now with three bands of relief:
a 4 m swell, a 90 cm lumpiness and a 20 cm grain. Texels leaning more than 8%
went from 5% of the map to 26%.

**The ravine** gets a generated tiling map instead (`tools/make_rock_detail.py`),
tiled every 16 m, and the tile size lives on the config beside the wall so the
two cannot disagree — the generator bakes a relief in real metres, not a
unitless bump, so a UV divisor that does not match it makes the rock the wrong
size.
Rock at half a metre is fractal and the same everywhere, so modelling it would
be modelling noise and baking it would be a ten-minute round trip for a result
a closed-form function gives exactly — this runs in a second. It must tile, and
the tiling is asserted: not "the opposite edges are equal", which would fail a
map that tiles perfectly, but "the wrap step is no larger than an ordinary
step", because a seam *is* a step out of scale with its neighbours.

**The machines** bake from a bevelled, subdivided copy of the low-poly, and
that copy was subdivided only enough to hold the bevel. At that density a
displacement has nothing to displace, so a machine baked as glass with
chamfers: the normal map carried the edges and nothing at all between them. It
now subdivides three levels and carries two displacement bands at 1.2 mm and
0.35 mm — a texture, not a dent. Anything bigger reads as damage.

## The vines are painted

A material slot is one flat colour over every triangle assigned to it, which is
all a 500-triangle prop needs. Four thousand vines is not that: they all came
out of the bake identical, and a web whose every strand is the same value reads
as a diagram of a web. `MB` carries optional per-vertex colour now, and
`vine_paint` varies three things that are three different arguments — a hue and
value jitter per vine so neighbours differ, a dark root and pale tip along each
one, and a lift where the tube swells, which is what makes a swelling read as
a swelling. Props pass no colour and so get no colour attribute at all, leaving
`COLOR_0` to the vertex-AO bake exactly as before.

## Scatter: order is priority

`Dressing.place` keeps **one shared `taken` list**, so each entry has to find
room around everything placed before it. Spires were last and could place 9 of
45 — not because the high ground was full, it had twice the area it needed, but
because 380 pods and tendrils had already been strewn across it.

Big and structural first, clutter last. The build now prints **legal square
metres per rule** alongside the count, because a shortfall is otherwise
indistinguishable between "the band is empty", "the clearance is too wide" and
"the clusters landed badly".

The rim band matters most: in the reference the roots and vines *are* the island
edges, so tendrils and coral are banded into 0.18–0.42 rather than scattered
over the tops. 94 props end up on the cliff edges.

## The HUD

Anchors only, no fixed screen sizes, so the same tree works on a 2400×1080 phone
and on a tablet. Panels take the **edges** and the battlefield keeps the middle —
which on a phone also keeps both thumbs off the part being looked at.

Top bar (mass, capacity, explored) · corner map · centre alert and job bar ·
right column (radar, then build tiles, scrolling) · bottom-left reforge ·
bottom strip · bottom-right drone target.

The corner map is **drawn, not rendered**. A second viewport and camera would
cost a whole extra pass over the scene for a panel 300 px wide; this stretches
the fog texture and stamps a dot per contact, which is a handful of draw calls
and reads better at that size — a real top-down render of a 150 m map at 300 px
is mush.

The camera sits about 70° down, not flat. The reference survey map is drawn
straight overhead and a camera copying it exactly would hide every silhouette in
the game — arches, spires and machines all become circles.

## Known wrong, not yet fixed

- **Every island edge glows.** The pool glow keys off `impassable_below`, and
  the new cliff rim occupies the same height band as a basin, so the rims light
  up like the pools do. It happens to resemble the reference's glowing root
  borders, which is why it is not a blocker — but it is an accident, not a
  decision. The real fix is a **water mask**: a second channel in the height
  texture marking which low ground is actually a pool, since "enclosed basin"
  versus "outer edge" is a topological distinction a per-fragment shader cannot
  make. Not built.
- **The island tops still render dark in the Blender preview.** The palette was
  brightened for open sky (it was written for ground lit from inside a cavern),
  but the preview's exposure is not Godot's and the glowing rims dominate it.
  The game may well look right where the preview does not — unverified.
- **The preview's island edges are stair-stepped.** It drops whole quads at the
  world edge; the game discards per fragment and will have a smooth edge.

---

# The painterly pass

Researched rather than guessed. Findings first, because two of them ruled out
the obvious answer.

## What the obvious answer is, and why it is not this one

**Kuwahara** is the standard painterly post-process: for each pixel it divides a
window into sectors, finds the sector with least colour variance, and takes that
sector's average — blurring while preserving hard edges, which is what makes a
render look like paint. The classic variant is the one suited to real time;
anisotropic is better-looking and dearer. Larger kernels denature the image, so
there is a balance to strike between kernel size and effect strength.

Two things rule it out here, for now:

1. **Godot's compositor is only half-supported on the Mobile renderer.** The
   docs say the compositor works on Mobile and Forward+, but the PR that added
   it gave *full* support only to Forward+ and *limited* support on Mobile, and
   in practice the colour texture has no storage flag there, so a compute
   shader cannot write it. The clean route is unavailable.
2. **Cost.** A circular-kernel Kuwahara is on the order of fifty texture fetches
   per pixel. The one well-known Godot implementation claims 1080p60 — *"on any
   modern computer"*. That is a desktop claim, and this runs at 2400×1080 on a
   Mali-G68 with no measured frame-time headroom at all.

The screen-reading route (a full-screen quad sampling `hint_screen_texture`) *is*
available — the two Mobile-renderer artifact bugs, godotengine/godot#88786 and
#91474, are both **closed**, fixed by PR #91480, and we are on 4.7.2. So
Kuwahara stays on the table as a High-preset option once there are frame numbers
to spend. It is not the foundation.

## What is built instead

**Triplanar-style projection of a stroke field, at material level.** The reason
this is the right technique for *this* project, specifically: it needs **no UVs**,
which is exactly why it survives ground that changes shape every time the player
digs. There is nothing to re-unwrap because there was never an unwrap. That is
the standard answer to texturing deforming geometry, and it happens to be the
only one compatible with a heightfield displaced in a vertex shader.

Brush-stroke shading works by **bending the normal through a stroke field before
lighting**, which is how an artist shades a transition — marks, not a gradient.

Four parts, all gated behind one `paint_strength` knob that skips the work at
zero:

| | |
|---|---|
| **stroke direction** | from the heightfield gradient — the same central difference the vertex stage already takes. Strokes run **along the contour**, describing the form the way a painter's would. |
| **stroke normal bend** | one fbm plus two taps for the gradient. Three noise evaluations, against Kuwahara's fifty fetches. |
| **stroke tone** | the same field shifts the **albedo**. See below — this is the half that matters. |
| **banded light + ink** | a custom `light()` quantises N·L into steps, with the seam between steps darkened. |

## Three things that were wrong, found by looking

**Bending the normal alone did almost nothing.** Under a high sun on a plateau
top, every pixel has the same N·L, so a normal-only effect changes nothing
across most of the map. A painter laying marks on a flat field varies the
*colour*. Adding `paint_tone` — the stroke field modulating albedo — is what
made the pass visible at all.

**The stroke direction collapsed on flat ground.** Normalising a near-zero
gradient gives a direction that flips pixel to pixel, so every plateau — most of
the playable map — got noise instead of strokes. Where the gradient dies it now
falls back to a slowly-rotating field: still coherent over a few metres, just
not tied to a slope that is not there.

**The strokes were sub-pixel.** The first values made a mark about 90 cm long and
**12 cm across**, which from the RTS camera is under a pixel wide, so every
stroke aliased into noise. They are now roughly four metres by most of a metre.
Size turned out to matter more than every other parameter combined.

## And one bug this finally forced out

The "every island edge glows" problem is **fixed**. Height alone genuinely
cannot distinguish a pool from the outer rim of a plateau — they sit in the same
band, and a fragment can only see its own cell, not the shape around it. So
`Heightfield` now carries a **water mask** that the map author stamps (a
`plateau` op with `"water": true`), uploaded once as its own texture because
digging changes heights constantly and never creates a lake. The pool glow
multiplies by it. The neon halo is gone and the pools are discrete.

## Looking at it: `tools/paint_preview.py`

The Blender preview cannot run a Godot shader, so every earlier picture was an
approximation drawn by a different renderer — which is exactly how two of them
came back lying about the colours.

For a straight-down orthographic view none of that is necessary: every input the
fragment shader has is computable per pixel without a rasteriser. So this is a
**direct port of `terrain_lit.gdshader` evaluated in numpy**, rendering paint-off
and paint-on side by side. It reads the paint values **out of the same JSON the
build exports**, because an earlier version kept its own copy and they had
drifted apart within the hour.

It is not the game — no tonemapper, no shadows, no props, flat ambient — but the
bands, strokes, posterise and banded light are the same arithmetic.

## Honest state

The pass works end to end and the difference is visible, but it is **subtle, not
the bold illustrated look of the reference**. Those references are 2D
illustrations with hand-drawn linework; a procedural stroke field will not reach
them. Two things would close most of the remaining gap, and neither is built:

- **Real brush-stroke textures** instead of procedural noise, projected
  triplanar. This means introducing the project's first texture assets — there
  are currently none at all.
- **Outlines.** The reference has linework around every shape; there is none
  here. Depth-and-normal edge detection is the usual approach and needs the
  screen-reading quad that Kuwahara would also use, so the two would share a
  pass.

Sources: [Kuwahara in Unreal](https://alexdiallo.wordpress.com/2019/06/23/the-kuwahara-algorithm-implementing-a-painterly-effect-in-unreal/) ·
[PeterEve/godot-kuwahara](https://github.com/PeterEve/godot-kuwahara) ·
[Godot compositor docs](https://docs.godotengine.org/en/stable/tutorials/rendering/compositor.html) ·
[#96737 compositor on Mobile](https://github.com/godotengine/godot/issues/96737) ·
[#91474](https://github.com/godotengine/godot/issues/91474) and
[#88786](https://github.com/godotengine/godot/issues/88786) screen-texture on Mobile ·
[Screen-reading shaders](https://docs.godotengine.org/en/stable/tutorials/shaders/screen-reading_shaders.html) ·
[Triplanar mapping](https://craftpbr.com/guides/triplanar-mapping)

---

# Ground materials, ink, and a real brush

Three things, all from looking at the reference again.

## 1. The ground is made of different stuff

The reference is **large flat areas of distinct material with hard organic
borders** — moss flats, bare rock, pale sediment at every waterline, dark loam,
and a root mat ringing each plateau. A height ramp cannot say that: two places
at the same altitude are routinely different materials.

`Heightfield` now carries a `material_id` byte per cell, classified **after** the
ops (a material depends on the shape they left behind — how steep, how near the
water, how near the world's edge) and uploaded once as an R8 texture. Five slots,
each with two colours a painter would have mixed, its own roughness, its own
stroke size, and its own filament-web strength.

| | share | where |
|---|---|---|
| sediment | 31% | shorelines and a narrow band above the waterline |
| loam | 25% | broad noise patches, so the flats are not one colour |
| vine | 21% | a 2.5 m border at every plateau rim |
| moss | 21% | the open flats |
| rock | 3% | steep faces and ridge tops |

The shader samples the map with **`filter_nearest` and a jittered position**. A
blurred lookup would return an index halfway between rock and moss, which is not
a material; jittering the sample instead keeps every read a real slot and gives
the torn painterly border the reference has.

**This is what keeps the vines to the borders.** The glowing web is no longer a
global effect — its strength is a per-material property, and only the root mat
has a real value. The open flats are clear.

Two numbers had to be found by measuring, not guessing:

- **The root mat at 5 m wide covered half the walkable ground**, and bare rock
  never appeared at all, because the mat is applied last and overrode it. On
  plateaus 20 m across, a border is 2.5 m.
- **Sediment keyed to `rough_below` swallowed the whole cliff band** and became
  40% of the map. Sediment is a shoreline, not an altitude.

## 2. Ink, from depth alone

The usual Godot outline reads the normal-roughness buffer. **That does not
compile on the Mobile renderer** — `normal_roughness_buffer` is only defined in
the Forward+ GLSL and left undeclared in Mobile
([#78411](https://github.com/godotengine/godot/issues/78411)); the proposal to
add it ([#11992](https://github.com/godotengine/godot-proposals/issues/11992))
is still open. Every normal-based outline tutorial is unavailable to us.

Depth is available everywhere, so it all comes out of the depth buffer:

- a **first difference** catches silhouettes — where one thing ends and
  something much further away begins
- a **second difference** (a Laplacian) catches creases — on a flat surface the
  centre sample equals the average of its neighbours, so anything that does not
  is a fold

Both divided by depth, making the test scale-invariant: a crease forty metres
out inks as readily as one under the camera.

It runs on a full-screen quad written straight to clip space — a
`MeshInstance3D`, not a `ColorRect`, because the depth texture is unavailable to
canvas_item shaders ([#74464](https://github.com/godotengine/godot/issues/74464)).
A screen-reading pass forces a resolve on a tile-based mobile GPU, so its cost is
*structural* rather than proportional; it is **off on the Low preset** so the
phone can say what it costs.

First values inked the cliffs as a solid dark wash rather than a line — a rim's
second difference is enormous next to a plateau's. Ink is a line.

## 3. A real brush, and it is *cheaper*

`textures/brush_strokes.png` is **the first texture asset in this project.**

```
R  stroke value
G  d(value)/dx, remapped 0..1
B  d(value)/dy, remapped 0..1
A  canvas grain
```

Packing the gradient means one fetch gives the value **and** the slope needed to
bend the normal. It replaces three fbm evaluations — twelve value-noise lookups,
forty-eight hash operations — so this is the unusual case where the
better-looking option is also the faster one.

Every stroke on the sheet points along +X; the shader rotates the *lookup* per
fragment so the marks follow the contour. The texture must carry no direction of
its own for that to work.

Generated deterministically by `tools/make_brush_texture.py` in three passes —
broad laid-in marks, mid strokes, fine detail — with tapered ends, bristle
streaks, and paint load running out toward the end of each stroke. Stamps wrap
at the edges so the sheet tiles.

Two things it needed:

- **Bristle frequency** started at 0.55–1.5 rad/px — a four-to-eleven pixel
  period — and 246 stacked strokes read as *scan lines*. A few streaks per
  stroke is what a loaded brush leaves.
- **`detect_3d/compress_to` had to be turned off.** Godot auto-switches a
  texture to VRAM compression once it sees it used in 3D, and block compression
  treats the packed gradient channels as colour and smears them.

## Still not the reference

Closer, but these are illustrations and this is a real-time renderer. What is
genuinely still missing: the material borders are organic but the underlying
cell grid still shows at close range, the props are untouched by any of this
(they get no strokes and no material), and there is no hand-drawn linework
*inside* shapes the way the reference has.

**And none of it is measured.** Ink adds a screen-reading pass, the brush adds a
texture fetch, materials add one more. The phone has not seen any of it.
