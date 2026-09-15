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
