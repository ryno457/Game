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

That assertion immediately earned itself. Per-channel medians still clipped
**22% of `night.exr`** — and for a reason the flat-sky cases could never show.
The reference is a copy of the *terrain*, not a flat card, and `night.exr` has
a moon in it. A slope tilted toward a moon genuinely receives more light than
level ground does, so "the median open surface" is not a ceiling at all. The
divisor is now the **99th percentile** of the open reference: the best-lit open
surface this terrain has, which is what every occluded texel is a fraction of.
`night` then clips 1.1%.

A third, duller bug sat underneath both: `STUDIO` was built from
`os.path.dirname(bpy.__file__)`, which lands in `<root>/scripts/modules/bpy`
while the datafiles are at `<root>/datafiles` — two directories too deep. It
raised `FileNotFoundError` only on the branch that lists the built-in skies,
so every `game` run during development passed and all three Poly Haven
candidates failed the moment they were asked for. `bpy.utils.resource_path`
now anchors it.

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

## The four candidates, and a prediction that did not survive

640x477, 40 samples, measured inside the footprint:

| sky | mean | tint (R/G/B) | clipped | reads as |
|---|---|---|---|---|
| game | 0.47 | 0.60 / 0.91 / 1.48 | 3.0% | flat blue, heavy firefly speckle |
| night | 0.28 | 1.13 / 1.00 / 0.86 | 0.6% | warm brown, soft clear form |
| forest | 0.44 | 0.88 / 0.97 / 1.15 | 0.1% | neutral grey, crisp form |
| sunset | 0.43 | 0.75 / 0.89 / 1.36 | 0.4% | blue with a warm rim on the ravine |

**The generated `game` sky is the worst of the four, and the reasoning that
recommended it was wrong.** The argument above — that every downloaded HDRI is
a photograph of somewhere on Earth and this biodome's own sky is the only
honest light for it — is true about *colour* and beside the point about
*form*. What a bake like this is for is directional shading: a bright region
somewhere in the sky is what makes a vine cast a soft shadow and a nodule read
as round. `ProceduralSkyMaterial` is a smooth four-stop gradient dome with no
bright source anywhere in it, so it lights every exposed texel from every
direction almost equally and the map comes out nearly flat. Its dimness makes
it worse: an open-ground irradiance of 0.039 against forest's 2.31 means the
same 40 samples carry far less signal, and the fireflies that survive are
scaled up by the small divisor into the white speckle visible across it.

So the tint argument and the form argument point at different candidates, and
form is the one that cannot be fixed afterwards. A tint can: the map is
per-channel, and scaling its three channels is a multiply. A flat map has no
shading in it to recover.

That makes the real choice "which sky has usable directionality", with colour
as a correction applied after — not "which sky is the most honest about this
biodome". Recorded because the prediction was made confidently in this same
document two sections earlier, and the render disagreed with it.

## Chosen: night, re-tinted, and combined with the painted look

`night` (Poly Haven `moonless_golf`, CC0) for its shading, re-tinted to the
game's own sky colour. The two arguments pull apart and only one is fixable
afterwards — the map is per-channel, so a tint is a multiply, while a flat map
has no shading to recover.

### The re-tint is anchored on the floor average, not on open ground

Open ground is the more principled reference and it overshoots. Under a sky
with a warm moon, shaded texels see proportionally less of the moon and are
already bluer than open ground is, so correcting the open-ground ratio pushes
the shaded majority — which is almost the whole map — past the target:

| anchor | resulting floor tint | target |
|---|---|---|
| open ground | 0.50 / 0.82 / 1.68 | 0.59 / 0.90 / 1.51 |
| floor average | **0.589 / 0.904 / 1.507** | 0.59 / 0.90 / 1.51 |

Two bugs surfaced on the way, both of the kind that look like success. The
printed tint was taken off the *raw* bake, so a run that had just swapped warm
for cold printed the warm number and the retint appeared to do nothing. And
`foreach_set` takes float32 while the retint multiply promotes to float64,
raising `incorrect sequence item type: d` — an error that names the dtype and
not the cause.

### How a coloured map enters a shader whose AO slot is scalar

Godot's `AO` output is one float, so a coloured irradiance map cannot go
straight into it. It is split:

- **luminance → `AO`**, which is what actually attenuates ambient light;
- **chroma → `ALBEDO`**, divided by that luminance so it averages to white and
  cannot darken the ground a second time.

That is a cheat, and it reads right in a scene whose light is mostly ambient.

`baked_sky` and `baked_ao` are the same occlusion measured two ways, so turning
one on means turning the other off. Nothing enforces it; it is written in the
uniform block and in the palette.

### The painted pass on top

The whole-map bakes and the Kuwahara filter compose, and the chain is three
commands with no new tool:

    bake_sky.py night 2048 64 --retint
    painterly.py build/hdri/sky_night_retint.png textures/ground_vines_sky.png \
        --size 4 --type anisotropic
    painterly.py <albedo> <painted albedo> --size 4 --type anisotropic

Painting the *ambient* map is the more interesting half. Flattening shading
into patches is most of what makes a render read as painted, and until now the
Kuwahara had only ever been run on albedo, where it measured a mild 17.3% of
the frame against a 3.9% noise floor.

## Combined with the painted look, measured, and blocked on a look decision

Both maps compose in the pipeline exactly as intended. Applied to the real
engine at any visible strength, they fail — and not for the reason predicted.

1600x900, fog open, forced re-import on both textures, against a 4.2% noise
floor:

| setting | mean d | >2 levels | detail | median luma | saturation | look_check |
|---|---|---|---|---|---|---|
| baseline (ships today) | — | — | 100% | 0.194 | 0.47 | **4/4 pass** |
| sky 1.0, tint 1.0 | 11.95 | 53.2% | 88% | 0.120 | 1.00 | 2/4 |
| + painted albedo | 11.85 | 53.1% | 88% | 0.117 | 1.00 | 2/4 |
| + painted ambient too | 11.92 | 53.1% | 84% | 0.117 | 1.00 | 2/4 |
| sky 0.30, tint 0.15 | 3.64 | 50.5% | 95% | 0.170 | 0.59 | 2/4 |
| sky 0.85, tint 0.25, exposure 1.45 | 7.32 | 95.6% | 112% | 0.180 | 0.66 | 2/4 |

### The painted pass is buried, not cancelled

Rows two and three are the same measurement — 53.2% against 53.1%, luma 0.120
against 0.117. The painted albedo, which on its own moved 17.3% of the frame,
contributes nothing once an ambient term this heavy is over it. Painting the
ambient map as well takes frame detail from 88% to 84%, which is real and is a
rounding error beside the lighting. The guess that the two treatments might
partly cancel was wrong in kind: the lighting does not fight the painting, it
buries it.

### Two failures, two different causes

**Luma** is the ambient term. The map's mean is 0.295 — the mat really does
block 70% of the sky — so a quarter of the frame's luminance is the honest
physical cost of applying it. `look_check` passes within 0.06 of 0.250, so the
floor is 0.190 and the build already sits at 0.194.

**Saturation** is the tint, and tracks it almost linearly: 0.47 at tint 0, 0.59
at 0.15, 0.66 at 0.25, a fully clipped 1.00 at 1.0. An earlier guess that this
came from ambient being attenuated while bio-luminescence was not is WRONG —
the shader already multiplies `emit` by `ao`, and the numbers point at the
tint instead.

### The usable envelope is invisible, and exposure does not rescue it

Solving both constraints at the current scene settings gives roughly
`baked_sky` 0.05 and `baked_sky_tint` 0.10 — small enough that nothing would
be visible, which defeats the point of baking it.

Exposure was the obvious compensation and it does not work either. At 1.45 the
frame still reads 0.180, under the 0.190 floor, because exposure lifts
everything including what is already bright while the median sits in the
darkened ground. It also moved 95.6% of the frame, which is the whole game's
look changing, not the floor's.

### What this is actually waiting on

Not a knob. The biodome's lighting was authored against a floor with **no
occlusion at all**, and every value in `lighting.tres` — sun energy, ambient
energy, tonemap exposure — is balanced for that. Adopting real sky occlusion
means re-authoring those together with the map on, judged against the
reference paintings, rather than trying to slot it under numbers chosen
without it.

That is a look decision across the whole game, so it is left here rather than
guessed at. `baked_sky` and `baked_sky_tint` both ship at 0.0, the maps are
reproducible from two commands, and nothing in the current build has changed.
