# HDRI ambient light for the whole-map bake

Asked for: download free HDRIs, and choose one to light the texture maps with.
September 2026.

## Getting them: blocked everywhere, and already on disk

`polyhaven.com`, `api.polyhaven.com`, `dl.polyhaven.org`, `hdri-haven.com`,
`ambientcg.com`, `openfootage.net` and `hdrmaps.com` all answer 403 to CONNECT
through this environment's egress proxy. Nothing could be downloaded.

Nothing needed to be. Blender ships eight 1024x512 equirectangular HDRIs in
`datafiles/studiolights/world`, and its own `license.txt` says what they are:

> All HDRIs are licensed as CC0.
> These were created by Greg Zaal (Poly Haven https://polyhaven.com).

So they are Poly Haven HDRIs, CC0, sitting in the `bpy` install. Measured:

| | mean | sky-half mean | tint (R,G,B) |
|---|---|---|---|
| night | 0.116 | 0.202 | 1.19 / 1.01 / 0.81 |
| sunset | 0.461 | 0.766 | 0.83 / 0.88 / 1.28 |
| sunrise | 0.440 | 0.813 | 1.01 / 1.03 / 0.96 |
| studio | 0.548 | 0.919 | 0.86 / 1.01 / 1.13 |
| courtyard | 0.557 | 0.783 | 0.96 / 0.91 / 1.12 |
| forest | 0.802 | 1.494 | 0.89 / 0.97 / 1.15 |
| interior | 0.863 | 1.405 | 1.18 / 1.02 / 0.79 |
| city | 1.028 | 1.787 | 0.96 / 0.99 / 1.05 |

## A ninth candidate, generated rather than downloaded

Every one of those is a photograph of somewhere on Earth. This is a sealed
biodome at night on another planet, and its sky is already specified — four
colours and an energy in `data/gameplay/lighting.tres`, which the game renders
through `ProceduralSkyMaterial`. Lighting this ground with `sunset.exr` would
light it with Venice.

So `bake_sky.py game` builds an equirectangular HDRI from that resource: the
same four-stop gradient Godot uses, zenith to horizon above and horizon to
nadir below, times `sky_energy`. It is a real HDRI — float, equirectangular —
and it is the only candidate whose light matches what the engine will render.

## What the bake produces

`tools/blender/bake_sky.py` bakes the light a chosen sky throws onto the map,
off the same saved scene and the same unwrap as the other whole-map bakes, and
selected-to-active from 1.28 M faces of vine so the mat shades the ground it
lies on.

    ~/.cache/blender-venv/bin/python tools/blender/bake_sky.py game 2048 64

Two things it gets right that are easy to get wrong:

- **The colour pass is off.** What is wanted is irradiance — the light landing
  on the surface — not light times albedo. The ground's own colour is already
  in `detail_colour_tex`; multiplying it in here would apply it twice.
- **World light is `DIRECT` in Cycles.** Light straight from the background is
  not "indirect" merely because no lamp emitted it. Measured, not assumed: an
  indirect-only bake of this scene returns exactly zero.

### The divisor was wrong, and the fix was to measure it

The bake is irradiance in whatever units the HDRI carries — `night.exr` is a
hundredth of `city.exr` — so it has to be normalised into a fraction of what
open ground receives. The first version divided by the map's own 99.5th
percentile, on the reasoning that the brightest half-percent must be open sky.

It is not. The vine mat covers the whole floor, so the brightest texel is only
the least shaded one. The map read 0.690 where a Cycles AO bake of the same
scene read 0.840, and the gap survived every explanation tried for it —
resolution (0.840 at 384 too) and AO ray distance (0.828 at 100 m).

It now divides by a real measurement: the same target, copied and lifted a
kilometre clear of every occluder, baked under the same world. Nothing above it
and nothing beside it, so what it receives *is* open sky. That divisor came out
at **0.9914** for a uniform white world — which is to say the old percentile
guess had been close all along, and the gap is not normalisation.

### ...and then the measured divisor was wrong too, in a way only colour shows

The reference bake returned one scalar: the median across all three channels.
That is correct for a white sky and ruinous for a coloured one, which is every
sky worth using. This biodome's own sky measures

    open ground irradiance [0.01499  0.02302  0.03849]

— blue is two and a half times red. Dividing all three by the *median* put blue
far above 1.0 everywhere, and the clamp to [0,1] then flattened it: **74.1% of
the map came back clipped**, the tint destroyed by the very step meant to
preserve it. The map was a blue-white sheet with a few dark spots, and it
looked plausible enough to ship.

Dividing instead by the **brightest channel** of open ground puts the brightest
channel of fully lit floor at exactly 1.0, leaves the other two below it by
however much the sky is tinted, and clips 3.7%. There is now an assertion that
fails above 5%, because a mostly-clipped map has thrown away the thing it was
baked for and still looks like a picture.

### The gap between AO and irradiance is still open

With both normalised properly, on the same scene:

| | mean inside the footprint |
|---|---|
| Cycles `AO` bake (`bake_ao.py`, shipped yesterday) | 0.840 |
| white-sky irradiance (`bake_sky.py white`) | 0.683 |

A uniform white sky *should* make the second a cosine-weighted version of the
first, so some difference is expected — AO samples the hemisphere uniformly,
irradiance weights it by the cosine, and a 0.9 m tangle of vine blocks a lot of
the directions the cosine favours. A difference of 0.157 is more than that
comfortably explains.

**The spatial comparison run so far does not settle it and should not be
quoted.** It correlated a 2048 AO map box-downsampled to 384 against a natively
baked 384 irradiance map. Both are dominated by vine detail finer than 384,
and the two paths to that resolution do not preserve it the same way, so the
0.43 correlation it reported measures the resampling as much as the maps.
Settling it needs both baked natively at the same resolution.

Until then: **irradiance is the better-defined quantity** — it is literally the
light arriving, in colour, with direction — and where the two disagree it is
the one to trust. The AO map committed in `69c4387` is a greyscale proxy for
it, and if the sky bake ships, AO should come out rather than multiply on top.
