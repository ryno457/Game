# Supplied shader guides

Three guides handed over on 2026-09-19, kept here as the PDFs they arrived as
plus this transcription of what each one actually says and what it is worth
to this project.

| file | technique | usable here |
|---|---|---|
| `drone-scan-demolecularization.pdf` | noise-threshold `discard` + glowing edge band | yes, directly |
| `3d-object-scanner.pdf` | UV-space sweeping scan line with a grid inside it | yes, directly |
| `glowing-trails-alien-blood.pdf` | Line2D trails + additive `CanvasItemMaterial` | **no — it is 2D**; see below |

---

## 1. Demolecularization — `drone-scan-demolecularization.pdf`

A spatial shader that erases a mesh by thresholding a noise texture, with a
lit band at the threshold so the erasure has a visible edge:

```glsl
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

uniform sampler2D albedo_texture : source_color;
uniform sampler2D noise_texture;
uniform vec4  scan_color : source_color = vec4(0.0, 1.0, 0.5, 1.0);
uniform float scan_progress : hint_range(0.0, 1.0) = 0.0;
uniform float edge_thickness : hint_range(0.0, 0.2) = 0.05;

void fragment() {
    vec4  albedo    = texture(albedo_texture, UV);
    float noise_val = texture(noise_texture, UV).r;
    if (noise_val < scan_progress) { discard; }
    float edge = step(noise_val, scan_progress + edge_thickness);
    ALBEDO   = mix(albedo.rgb, scan_color.rgb, edge);
    EMISSION = scan_color.rgb * edge * 2.5;
}
```

Driven by a tween on `scan_progress`, 0 → 1 over ~3 s, then `queue_free()`.

**Why it suits this project.** `cull_disabled, depth_draw_opaque` and no
alpha blending — which is the one combination this renderer is known to
handle. The project's own hard-won note (`_flat_mesh` in
`scenes/proto/proto_main.gd`) is that alpha + additive + depth-draw-disabled
submits perfectly and rasterises to nothing on Forward Mobile. `discard` is
not alpha blending, so this sidesteps that entirely.

**What to watch.** `discard` defeats early-Z. On a tile-based mobile GPU that
is a real cost, so it belongs on a handful of objects being scanned, never on
the terrain or on anything drawn by the hundred. `depth_draw_opaque` with
`discard` is correct and must stay.

**Run it backwards to build.** `scan_progress` 1 → 0 assembles the mesh out of
nothing with the same lit edge. One shader serves both the drone eating debris
and a module being forged.

## 2. Object scanner — `3d-object-scanner.pdf`

A band that sweeps in UV space, with a high-frequency grid inside it:

```glsl
float dist      = abs(UV.y - scan_position);
float scan_line = smoothstep(scan_width, 0.0, dist);
float grid      = clamp(sin(UV.x * 100.0) * sin(UV.y * 100.0), 0.0, 1.0);
scan_line      *= (grid + 0.2);
ALBEDO   = mix(base_color.rgb, scan_color.rgb, scan_line);
EMISSION = scan_color.rgb * scan_line * 2.5;
```

Non-destructive, so it is the *look at it* pass where the other is the *take
it apart* pass. Cheap: no discard, no blending, no second draw.

**Caveat for this codebase.** It sweeps in **UV.y**, not in world height. Any
mesh whose unwrap does not run bottom-to-top will sweep sideways or in
pieces. The machine and flora models here are built by
`tools/blender/build_*.py` and several carry a generated or atlas unwrap.
Sweeping on a world-space Y derived from `VERTEX` is the robust variant and
costs nothing extra.

## 3. Alien blood — `glowing-trails-alien-blood.pdf`

**This guide is written for 2D and does not transfer as written.** It builds
on `Line2D`, `CanvasItemMaterial`, `Sprite2D` and `global_position` as a
`Vector2`. None of those exist for 3D geometry. It is filed here for the
*reasoning*, which is sound and does apply:

- **Bake the bloom into the texture** rather than paying for a glow pass. A
  white core with a blurred coloured halo behind it, exported with alpha.
- **Additive blending** so overlapping halos add up like light instead of
  compositing like paint.
- **Cap the trail length** and drop old points, or the cost grows without
  bound.
- **Update every 2nd or 3rd frame** when many are alive at once, and let the
  width curve hide the gaps.
- **Kill them on a timer**, ~1.5 s, rather than when they leave the screen.

The 3D translation for this project is a `MultiMesh` of camera-facing quads
built the way `_instancer()` already builds the tracers, the beams and the
shield bubbles — all of which render here. The additive part is exactly what
this renderer will not do, so the glow has to come from an **opaque emissive**
material, which is what the drone scan and the health bars were eventually
forced into for the same reason.
