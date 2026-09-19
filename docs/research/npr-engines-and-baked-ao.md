# Three NPR engines, and the AO that was missing from the bake

Asked for: BEER / Malt, PseudoPainter, RenderMan, render tests with all three,
and whether AO has been applied to the baked textures. Gathered September 2026.

**None of the three could be obtained here.** The AO answer is **no — and that
was a real gap**, now closed and measured.

---

## The three engines

### BEER / Malt — cloned the source, cannot run it

Malt is the rendering framework; BEER is the NPR pipeline built on it. MIT
licensed, and `git clone https://github.com/bnpr/Malt.git` works (11 MB).

It still cannot run here, for three independent reasons:

1. **The source tree is not the add-on.** The repo's root `__init__.py` is a
   deliberate decoy — `"name": "Oops! You downloaded the wrong BlenderMalt
   file."` The installable package is a release zip that also bundles PyOpenGL
   and a compiled `CBlenderMalt` extension. The clone has
   `CBlenderMalt.cpp` and a `CMakeLists.txt`, no binaries, and no
   `.Dependencies-<pyver>` directory.
2. **The release zip is unreachable.** `api.github.com` returns 403 through
   this environment's egress proxy, as does `malt3d.com`. Only scoped git
   clones get through.
3. **It targets a Blender this container does not have.** `BlenderMalt`'s
   `bl_info` asks for `"blender": (5, 1, 0)`. Available here: the apt build at
   4.0.2, and the `bpy` PyPI module at 5.0.1 — and the PyPI module has no
   add-on GUI at all, which is the only way Malt is driven.

The one requirement that *is* met is the GPU. Malt needs OpenGL 4.5 and this
container reports exactly that through Mesa's software rasteriser:

    OpenGL core profile version string: 4.5 (Core Profile) Mesa 25.2.8
    OpenGL renderer string: llvmpipe (LLVM 20.1.2, 256 bits)

So it is not hopeless on a real machine. It is unreachable on this one.

### PseudoPainter — blocked, and still the wrong tool

`barelyart.gumroad.com`, `gumroad.com` and `80.lv` all answer 403 to CONNECT.
Unchanged from the previous investigation, and the reason not to pursue it is
also unchanged and has nothing to do with the block: it is an **Eevee** shader,
this project bakes with **Cycles**, and the node these shaders are built on —
Shader to RGB — does not exist in Cycles. Baking a posterised Shader-to-RGB
material through this project's exact settings gives 0 non-black texels out of
16384. See `docs/research/painterly-addons.md`.

### RenderMan — blocked outright, nothing verified

`renderman.pixar.com` and `rmanwiki.pixar.com` both fail to connect. Nothing
about its licensing, its Blender bridge or its capabilities was checked, so
nothing is claimed here.

Worth saying plainly anyway: RenderMan is an offline film path tracer. Its
output is frames. Nothing it produces can run on an A54, so the only route from
it into this game is the same one every other option has — render, bake,
ship the texture. That route is already built, and the interesting question is
what is missing from it. Which is the next section.

### Why no render tests

There are none to give. Two of the three could not be downloaded at all and the
third cannot be assembled from what could. Rendering something in Cycles and
captioning it "roughly what an NPR engine might do" would be a picture of
nothing.

**The real comparison is available on a machine that can install them**, and it
is worth being clear about what it would settle. All three are *upstream of the
bake*: they change what the 2048 px whole-map textures look like, and the phone
never runs any of them. So the test that matters is not "which render looks
best" but "which bake, dropped into `textures/`, moves the in-engine frame" —
which `tools/screenshot.sh` plus `tools/look_check.py` already measures, and
which is exactly how the AO below was judged.

---

## AO on the baked textures: no, and now yes

The question was a good one. **The whole-map bake had no occlusion pass.**

`tools/blender/detail_source.py` writes three maps off the 1.28 M-face vine
scene — `_bake('NORMAL')`, a depth pass, and `_bake('DIFFUSE')` colour-only.
No AO. The project does have ambient occlusion in two other places, and neither
covers this:

| where | what it occludes | resolution |
|---|---|---|
| `tools/blender/_ao.py` | props, into **vertex colours** | per vertex |
| `TerrainBuilder.bake_shade()` | the **heightfield**, into the shade map's R | one value per metre |

`_ao.py`'s own docstring explains why it went to vertex colours: *"this project
has no textures — no image files, no UVs on any mesh"*. That stopped being true
when the terrain became a fixed shape with a real unwrap, and nothing went back
to revisit it.

The consequence is specific. The ground was occluded by its own large-scale
shape and by nothing else — the vine mat lying directly on it cast no contact
darkening at all, which is the cue that separates something *resting on* the
floor from a pattern *printed on* it.

### The bake

`tools/blender/bake_ao.py` bakes AO off the same saved scene the other three
maps came from, so it lines up texel for texel:

    ~/.cache/blender-venv/bin/python tools/blender/bake_ao.py 2048 64

2048x1526, 64 samples, ~12 minutes on CPU. Unlike its three siblings it is a
light integration, not a geometric pass — `detail_source.py` bakes normal and
colour at 4 samples and says why; 4 samples of a visibility integral is noise.

Inside the biodome's footprint:

| | mean | below 0.9 | below 0.6 |
|---|---|---|---|
| **baked AO, from the vine mat** | **0.862** | 52.2% | 3.5% |
| heightfield AO already shipping | 0.956 | — | — |

Roughly three times the darkening, from the geometry that was being ignored.

**The first version of that metric was wrong and read 0.663.** It averaged the
whole image, and 23% of the image is off-map void that the bake never writes,
which stays black, and black reads as fully occluded. The assertion guarding
the tool — *"AO came back essentially white, so the bake saw no sources"* —
would have passed on a bake that found nothing at all, purely on the strength
of its black margin. It now masks to the colour bake's silhouette.

### Wired up, off by default

- `shaders/terrain_lit.gdshader` — one fetch at the same whole-map UV, skipped
  entirely at zero, **multiplied** with the heightfield AO rather than mixed,
  because two independent occluders of the same point darken it twice.
- `scripts/resources/biome_palette.gd` — `baked_ao`, default 0.0.
- `scripts/systems/terrain_view.gd` — guarded by `ResourceLoader.exists` like
  the depth map, so a checkout without the bake gets the old look rather than a
  black floor.

Default zero means nothing changes until someone sets it, and the change can be
priced on its own — same discipline as `EffectsConfig`.

### What it does to the frame

Four frames out of the real engine, 1600x900, fog open, palette swapped and
Godot forced to re-import between each:

| frame | mean Δ | pixels >2 levels | median luma | look_check |
|---|---|---|---|---|
| same build again (**noise floor**) | 0.86 | 3.7% | 0.194 | pass |
| `baked_ao = 0.35` | — | — | 0.191 | pass |
| `baked_ao = 0.5` | — | — | 0.189 | **fail** |
| `baked_ao = 1.0` | 1.96 | **29.7%** | 0.184 | **fail** |

29.7% of the frame against a 3.7% floor: eight times the noise, and visibly the
right kind of change — the mat gets contact darkening and stops reading as a
pattern printed on the floor.

**But it fails the value check above ~0.4, and the reason is not the AO.**
`look_check.py` passes within 0.06 of a 0.250 median luma, so the floor is
0.190, and the build already sits at **0.194** — four thousandths of headroom.
Any darkening of any kind trips it. The AO did not make the frame too dark; it
found a frame that already was, with no margin left.

So there are two separate decisions here, and only the first is mine to
measure:

1. **0.35 is the most this build can take** and still pass. Measured, not
   extrapolated: 0.35 reads 0.191, 0.5 reads 0.189.
2. **Whether to spend the headroom elsewhere instead** — lift the exposure or
   the sun so there is room for contact shading — is a look question. A first
   attempt at pairing `baked_ao = 0.6` with `ambient_energy` 0.27 → 0.33 moved
   the median luma by 0.001, so ambient is not the lever; the sun or the
   tonemapper is. That one is not mine to decide.

Nothing is enabled. `baked_ao` ships at 0.0.
