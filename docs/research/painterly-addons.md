# Painterly Blender add-ons: what could be got, and what any of it is worth

Three things were asked about — PseudoPainter / Painterly Shaders on Gumroad,
Ucupaint, and the Kuwahara filter. Gathered September 2026, in this container,
with everything below measured rather than read off a product page.

Short version:

| | got it? | usable here? |
|---|---|---|
| PseudoPainter (Gumroad) | **no — egress blocked** | **no, and not because of the block** |
| Ucupaint | **yes**, GPL-3, registers in 4.0.2 | yes, but it is a job for a person with a stylus |
| Kuwahara | **no download needed** — built into Blender since 4.0 | yes, at bake time, and it measurably helps |

---

## PseudoPainter — could not download it, and would not have used it

`barelyart.gumroad.com` and `extensions.blender.org` both answer 403 to CONNECT
through this environment's egress proxy, as does `80.lv`, so the product could
not be fetched or its page read. `github.com` is reachable for public clones.

That is the boring reason. The interesting reason is that this pipeline could
not have baked it anyway, and that was worth establishing before asking anyone
to buy or unblock anything.

**These shaders are Eevee shaders, and this project bakes with Cycles.**
`tools/blender/detail_source.py` bakes the whole-map albedo with

    use_pass_direct = False, use_pass_indirect = False, use_pass_color = True

and Blender's bake operator is a Cycles feature. The node almost every
stylised Eevee material is built around is **Shader to RGB**, which turns
computed lighting back into a colour you can posterise or ramp — it is how the
brush strokes end up following the light rather than sitting on the surface
like a decal. Cycles has no such node.

Baking a posterised Shader-to-RGB material through this project's exact bake
settings produces:

    non-black texels 0 of 16384

A completely black texture. Not degraded — absent.

**One assumption on the way there was wrong and is worth recording.** The first
guess was that anything driven by shading would be erased, so a Mix Shader
between two BSDFs would not survive either. It survives perfectly: measured
against a Base-Color-driven version of the same stroke field, the shader-mixed
one baked **101.5%** of its local detail. Cycles evaluates the albedo of a
shader mix. So the line is not "texture bakes, shading does not" — it is
"Cycles bakes, Eevee-only nodes do not exist".

What that leaves: a painterly *procedural* setup that lives in Base Color —
noise, wave, ramps, bump — bakes fine, and could be written directly into
`detail_source.py` without any add-on. That is a real option. It is not what
was bought.

## Ucupaint — cloned, GPL-3, and it runs

    git clone --depth 1 https://github.com/ucupumar/ucupaint.git

15 MB, GPL-3, version 3.0.0, last commit the same day this was written. It
registers in the container's Blender 4.0.2 —

    INFO: Ucupaint 3.0.0 is registered!

— and installs its data model (`Scene.ypui`, `ShaderNodeTree.yp`) correctly.

Two snags, both this container's and neither the add-on's:

1. It imports `requests`, which Blender's bundled Python does not have. Put it
   on `PYTHONPATH` from a `pip install --target` directory.
2. Its bundled addon-updater checks GitHub for new branches inside
   `register()`, and with no egress the uncaught error aborts the whole
   registration. On a normal machine this never happens. Offline, the check has
   to be short-circuited before enabling.

It is a **layer-based texture painting tool** — Substance Painter's model,
inside Blender. It does not generate a painterly look; it lets a person paint
one, with layers, masks and blend modes, straight onto the UV unwrap the
terrain already has. That makes it the right tool for the job it is for, and
the wrong thing to evaluate headlessly: nothing here can tell you whether it is
pleasant to paint with. Worth keeping for when the project has art, which it
does not yet (CLAUDE.md: grey-box vertical slice, no art).

## Kuwahara — already in Blender, and it does something

No add-on and no download. `CompositorNodeKuwahara` has shipped since Blender
4.0, in Classic and Anisotropic variants with size, uniformity, sharpness and
eccentricity.

`tools/blender/painterly.py` runs a baked texture through it.

### Why bake time and not runtime

The filter replaces each pixel with the mean of whichever neighbourhood sector
has the lowest variance, so flat areas smear into patches and edges stay put.
That is also why it is expensive: classic at radius r costs 4(r+1)² taps, which
is 64 at r=3 and 196 at r=6, and the anisotropic variant adds a structure
tensor on top. The full-screen ink pass this game already runs
(`shaders/outline.gdshader`) is **six** taps — one colour, five depth — and
CLAUDE.md risk 4 says even that is unpriced on the A54. A Kuwahara pass is an
order of magnitude more than the most expensive full-screen thing here.

It does not need to be a runtime pass. Deformation is out of the design, the
terrain is a fixed shape with a real unwrap and a whole-map baked albedo, so
the filter can run once and ship as pixels.

### What it costs the texture

On `textures/ground_vines_c.png`, 2048x1526, local detail kept:

| setting | detail kept |
|---|---|
| classic 6 | 28% |
| anisotropic 4 | **43%** |
| anisotropic 6 | 34% |
| anisotropic 10 | 26% |
| anisotropic 16 | 21% |

Classic mushes the vine mat at any useful radius. Anisotropic at 4 turns the
vine strands into strokes while leaving them legible; by 16 the vines are gone.

### What it does to the frame — and the control that mattered

The texture is not the picture. Four frames were taken out of the real engine
at 1600x900 with the fog open, swapping the bake each time, and compared
against the unfiltered original:

| frame | mean Δ | pixels >2 levels | frame detail |
|---|---|---|---|
| same texture again (**the noise floor**) | 0.84 | 3.9% | 100% |
| kuwahara anisotropic 4 | 1.17 | **17.3%** | 98% |
| kuwahara anisotropic 16 | 2.05 | **30.8%** | 97% |
| bake replaced by one flat colour | 3.14 | **46.5%** | 96% |

And against the reference paintings, via `tools/look_check.py`:

| frame | median luma | verdict |
|---|---|---|
| original | 0.194 | pass |
| anisotropic 4 | 0.192 | pass |
| anisotropic 16 | 0.193 | pass |
| flat | 0.185 | **fail** |

So the filter is free on the value structure, and at radius 4 it moves about a
third of the distance between "changed nothing" and "threw the bake away" —
which, looking at the frames, is the vine tracery reading as brushwork instead
of as fine noise.

**The first run of this said the opposite, and it was wrong.** It reported
every variant — including a bake flattened to a single colour — as changing
about 4% of the frame, with the frame's local detail unmoved at 100%. The
conclusion drawn from that was that the ground bake is nearly invisible in
game. Two things were missed:

1. **No noise floor.** Two screenshots of the *same* build differ by 3.9% of
   pixels at that threshold. Every "result" was at the floor.
2. **Godot never re-imported the texture.** `.godot/imported/` keys its
   compressed `.ctex` off an md5 sidecar. Overwriting the PNG behind the
   editor's back leaves the stale `.ctex` in place, so all four screenshots
   rendered the *original* texture while every file on disk said otherwise. The
   cache has to be deleted and `--headless --import` run before the shot.

This is the same lesson `tools/effect_cost.gd` already carries, arrived at from
a different direction: a measurement without a noise floor is not a
measurement, and a pipeline with a cache in it will happily report on a file it
did not read.

### Not applied

Nothing in this was committed to the bake. Whether the ground should read as
strokes rather than tracery is a look question, and the change is one command:

    ~/.cache/blender-venv/bin/python tools/blender/painterly.py \
        textures/ground_vines_c.png textures/ground_vines_c.png \
        --size 4 --type anisotropic
