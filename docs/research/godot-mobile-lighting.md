# What lighting Forward Mobile will actually run

Checked 2026-09-18 against Godot **4.7.2** — the engine's own `ClassDB`, the
renderer comparison page, and the feature list. Sources at the bottom.

## The trap that makes this worth writing down

**Every lighting class and property exists in `ClassDB` on every renderer.**
Probed directly:

```
AreaLight3D  YES    LightmapGI  YES    VoxelGI  YES    ReflectionProbe  YES
Environment: ssao_*, ssil_*, sdfgi_*, ssr_*, volumetric_fog_*  — all present
```

`ClassDB` is renderer-independent. You can set `env.ssao_enabled = true` on
Mobile, ship it, and get **no error, no warning, and no ambient occlusion**.
Nothing on screen tells you. That is why the list below matters more than the
API surface does: the API surface is a lie about what will run.

## The matrix

| Feature | Mobile | Note |
|---|---|---|
| DirectionalLight3D + shadows | **yes** | one directional shadow is what this project affords |
| OmniLight3D / SpotLight3D | **yes** | **8 per mesh, 256 per view** (Forward+ gets 512 per cluster) |
| **AreaLight3D** | **yes** | new in 4.7, 8 per mesh, has `area_texture` |
| Light projector textures | **yes**, documented | spot: single texture; omni: panorama. No renderer caveat in the docs |
| ReflectionProbe | **yes** | already on the pools here |
| LightmapGI (baked) | **yes** | but not usable on *this* map — see below |
| Glow / bloom | **yes** | on here |
| Distance + height fog | **yes** | on here |
| SSAO | **no** | bake AO instead — this project bakes it whole-map |
| SSIL | **no** | — |
| SSR | **no** | reflection probes instead |
| SDFGI | **no** | lightmaps instead |
| VoxelGI | **no** | lightmaps instead |
| Volumetric fog | **no** | distance fog instead |
| TAA, FSR2, 2D MSAA | **no** | FXAA or SMAA instead |
| Compute shaders | works, with a penalty | — |

## What that means for this game specifically

**Everything Mobile refuses is a way of getting INDIRECT light.** SDFGI,
VoxelGI, SSIL, SSAO and volumetric fog are five different answers to "where
does the light that is not coming straight from the sun come from". Mobile
gives you none of them, which is exactly why this project ended up with a tone
ramp, a whole-map baked normal and AO, and an ink pass: those *are* the
substitute, and they were arrived at the long way round.

So the interesting question is not "how do I turn SDFGI on" — there is no
script that does that, the renderer has no code path for it. It is **what else
adds soft light for a price Mobile can pay**. There is exactly one new answer
in 4.7:

### AreaLight3D — genuinely new, and Mobile runs it

A rectangle of light rather than a point, with its own texture slot, at the
same per-mesh budget as an omni. For a sealed biodome with a roof this is the
right shape of light: wide and soft from overhead, without scattering a dozen
omnis to fake it.

Added as `LightingConfig.area_fill_*` and `LightingRig.build_area_fill()`.
**It ships off**, because it is one more light in a frame budget that has never
been measured on the phone, and this project's rule is that nothing is
affordable until it is re-soaked on the A54. The **LIGHTS** button in the test
build turns it on and restarts the timings, so it gets measured rather than
assumed.

### LightmapGI is still out, and not for a renderer reason

Mobile supports it. This map cannot use it: the terrain mesh is generated at
runtime, so it has no UV2 to bake into, and `LightmapGI.bake()` is not exposed
to script. Both of those are about *this* mesh, not about Mobile. Recorded here
because "Mobile supports lightmaps" is true and misleading in the same breath.

### The projector result needs re-testing on real hardware

A `SpotLight3D` with anything in `light_projector` contributes **exactly zero**
on this machine — measured on a bare scene, on Forward+ and Mobile alike, with
an imported texture and with a runtime `ImageTexture`, while the same spot
without a projector lights the scene fine (0.0418 → 0.0000).

The docs list projector textures as a core feature with **no renderer caveat**.
That makes software Vulkan (lavapipe, which is what this container has instead
of a GPU) far and away the likeliest culprit — but a lavapipe limitation and an
engine bug cannot be told apart without a real GPU. **One press of the LIGHTS
button on a phone settles it.** If the cookie appears there, the canopy can
come off the shader path and go back to being one texture fetch inside the
light loop, which is cheaper than what ships today.

This is the honest state: not "projectors are broken", but "projectors are
broken *on the only renderer this machine has*, and the documentation says they
should not be".

## What a custom script can and cannot do

It cannot add SDFGI or volumetric fog. Those are renderer code paths; there is
no script-side switch and no shader that substitutes for a voxel cascade.

What a custom shader **can** do, and what this project already does:

- **AO** — baked whole-map, plus curvature in `terrain_lit.gdshader`. This is
  a straight replacement for SSAO and a better one at a fixed camera angle.
- **Indirect colour** — the 1D tone ramp in the custom `light()`, which is
  where the bounce light in this game actually comes from.
- **Light shafts / a canopy** — the cast layers in the terrain shader, in world
  space, which is what stands in for both volumetric fog and the projector.
- **Fake reflections** — reflection probes on the pools, measured at 0.97/255
  and shipped **off** with the number recorded.

The pattern across all four: Mobile will not compute it per-frame, so compute
it once and sample it. That is the whole strategy and it has not changed.

## Sources

- [Overview of renderers (docs source)](https://github.com/godotengine/godot-docs/blob/master/tutorials/rendering/renderers.rst)
- [List of features (docs source)](https://github.com/godotengine/godot-docs/blob/master/about/list_of_features.rst)
- [Godot 4.7 release notes](https://godotengine.org/releases/4.7/) — AreaLight3D
- Direct `ClassDB` probe of the 4.7.2 binary in this repo

`docs.godotengine.org` and `godotengine.org` are both blocked by this
container's egress proxy; the two docs pages were read from their source `.rst`
on GitHub, which is the same text, and the 4.7 release contents came from
search result summaries rather than the page itself.
