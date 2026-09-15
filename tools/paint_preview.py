"""Render the terrain shader's own arithmetic on the CPU, for a look at it.

The Blender preview cannot run a Godot shader, so every picture of this map so
far has been an APPROXIMATION of the game drawn by a different renderer — which
is exactly how the last two previews came back lying about the colours.

For a straight-down orthographic view none of that is necessary. Every input
the fragment shader has is computable per pixel without a rasteriser: the world
position is the pixel, the height comes from the same .r32 Godot loads, and the
normal is the same central difference the vertex stage takes. So this is a
direct port of terrain_lit.gdshader, evaluated in numpy.

It is not the game — there is no tonemapper, no shadow map, no props, and the
ambient term is a flat approximation. But the bands, the strokes, the posterise
and the banded light are the SAME arithmetic, so if it looks painted here the
shader is painting.

    ~/.cache/blender-venv/bin/python tools/paint_preview.py build/biodome out.png
"""
import json
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)) + "/blender")

DATA = sys.argv[1] if len(sys.argv) > 1 else "build/biodome"
OUT = sys.argv[2] if len(sys.argv) > 2 else "build/biodome/biodome_01_paint.png"
RES = int(sys.argv[3]) if len(sys.argv) > 3 else 1100

meta = json.load(open(os.path.join(DATA, "biodome_01.json")))
CX, CZ = meta["cells_x"], meta["cells_z"]
HS = meta["height_scale_m"]
IMPASSABLE, ROUGH = meta["impassable_below"], meta["rough_below"]
VOID = meta.get("void_below", 0.0)
PAL = meta["palette"]
heights = np.fromfile(os.path.join(DATA, "biodome_01.r32"),
                      dtype="<f4").reshape(CZ, CX)
_wpath = os.path.join(DATA, "biodome_01_water.r32")
water = (np.fromfile(_wpath, dtype="<f4").reshape(CZ, CX)
         if os.path.exists(_wpath) else np.zeros_like(heights))


def _s2l(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def rgb(h):
    return np.array([_s2l(int(h[i:i + 2], 16) / 255.0) for i in (0, 2, 4)])


# --- the shader's noise, ported exactly --------------------------------------
def hash2(x, y):
    p3 = np.stack([x, y, x], -1) * 0.1031
    p3 -= np.floor(p3)
    yzx = np.stack([p3[..., 1], p3[..., 2], p3[..., 0]], -1)
    p3 = p3 + np.sum(p3 * (yzx + 33.33), -1)[..., None]
    v = (p3[..., 0] + p3[..., 1]) * p3[..., 2]
    return v - np.floor(v)


def vnoise(x, y):
    xi, yi = np.floor(x), np.floor(y)
    xf, yf = x - xi, y - yi
    u = xf * xf * (3.0 - 2.0 * xf)
    v = yf * yf * (3.0 - 2.0 * yf)
    a = hash2(xi, yi)
    b = hash2(xi + 1.0, yi)
    c = hash2(xi, yi + 1.0)
    d = hash2(xi + 1.0, yi + 1.0)
    return (a + (b - a) * u) + ((c + (d - c) * u) - (a + (b - a) * u)) * v


def fbm(x, y):
    return (vnoise(x, y) * 0.55 + vnoise(x * 2.3, y * 2.3) * 0.27
            + vnoise(x * 5.1, y * 5.1) * 0.18)


def sample_h(wx, wz):
    """Bilinear, matching the height texture's filter_linear."""
    x = np.clip(wx, 0, CX - 1.001)
    z = np.clip(wz, 0, CZ - 1.001)
    x0, z0 = np.floor(x).astype(int), np.floor(z).astype(int)
    fx, fz = x - x0, z - z0
    x1, z1 = np.minimum(x0 + 1, CX - 1), np.minimum(z0 + 1, CZ - 1)
    return (heights[z0, x0] * (1 - fx) * (1 - fz) + heights[z0, x1] * fx * (1 - fz)
            + heights[z1, x0] * (1 - fx) * fz + heights[z1, x1] * fx * fz)


def sample_mask(wx, wz):
    x = np.clip(wx, 0, CX - 1.001).astype(int)
    z = np.clip(wz, 0, CZ - 1.001).astype(int)
    return water[z, x]


def normalize(v):
    return v / np.maximum(np.linalg.norm(v, axis=-1, keepdims=True), 1e-9)


# --- render -------------------------------------------------------------------
def render(paint):
    """One panel. `paint` is the paint_strength the shader would be given."""
    ar = CZ / CX
    W, H = RES, int(RES * ar)
    wx = np.linspace(0, CX - 1, W)[None, :].repeat(H, 0)
    wz = np.linspace(0, CZ - 1, H)[:, None].repeat(W, 1)

    h = sample_h(wx, wz)
    e = 1.0
    hl, hr = sample_h(wx - e, wz), sample_h(wx + e, wz)
    hd, hu = sample_h(wx, wz - e), sample_h(wx, wz + e)
    n = normalize(np.stack([(hl - hr) * HS, np.full_like(h, 2.0 * e),
                            (hd - hu) * HS], -1))
    wy = h * HS

    # paint_strokes(): direction from the heightfield gradient, so strokes run
    # along the contour rather than in a fixed screen direction.
    tone = np.zeros_like(h)
    if paint > 0.0:
        down = np.stack([n[..., 0], n[..., 2]], -1)
        grade = np.linalg.norm(down, axis=-1, keepdims=True)
        ang = fbm(wx * 0.035, wz * 0.035) * 2.0 * math.pi
        drift = np.stack([np.cos(ang), np.sin(ang)], -1)
        t = np.clip((grade - 0.02) / 0.16, 0, 1)
        t = t * t * (3 - 2 * t)
        down = normalize(drift + (down / np.maximum(grade, 1e-4) - drift) * t)
        along = np.stack([-down[..., 1], down[..., 0]], -1)
        spx, spz = wx * P["stroke_scale"], wz * P["stroke_scale"]
        rx = spx * along[..., 0] + spz * along[..., 1]
        rz = (spx * down[..., 0] + spz * down[..., 1]) * P["stroke_stretch"]
        se = 0.25
        c0 = fbm(rx, rz)
        tone = (c0 - 0.5) * P["paint_tone"] * paint
        dx = fbm(rx + se, rz) - fbm(rx - se, rz)
        dz = fbm(rx, rz + se) - fbm(rx, rz - se)
        bend = along * dx[..., None] + down * dz[..., None]
        n = normalize(n + np.stack([bend[..., 0], np.zeros_like(h), bend[..., 1]], -1)
                      * P["stroke_depth"] * paint)

    slope = 1.0 - np.clip(n[..., 1], 0.0, 1.0)

    # bands
    t_low = np.clip((h - IMPASSABLE) / max(1e-3, ROUGH - IMPASSABLE), 0, 1)
    t_high = np.clip((h - ROUGH) / 0.42, 0, 1)
    base = np.where((h < ROUGH)[..., None],
                    POOL + (ROUGHC - POOL) * t_low[..., None],
                    GROUND + (RIDGE - GROUND) * t_high[..., None])
    base = np.where((h < IMPASSABLE)[..., None], POOL, base)
    cliff_t = np.clip((slope - 0.35) / 0.45, 0, 1)
    cliff_t = cliff_t * cliff_t * (3 - 2 * cliff_t)
    base = base + (CLIFF - base) * cliff_t[..., None]

    m = fbm(wx * 0.09, wz * 0.09)
    grit = fbm(wx * 1.7, wz * 1.7)
    base = base * (0.82 + 0.36 * m)[..., None] + ((grit - 0.5) * 0.05)[..., None]
    macro = fbm(wx * P["macro_scale"], wz * P["macro_scale"])
    base = base * (1.0 + (macro - 0.5) * 2.0 * P["macro_strength"])[..., None]
    bands_n = vnoise(wy * 2.7, wx * 0.09 + wz * 0.07)
    strie = np.clip((slope - 0.25) / 0.5, 0, 1)
    strie = strie * strie * (3 - 2 * strie)
    base = base * (1.0 + (bands_n - 0.5) * P["striation_strength"] * strie)[..., None]

    # emission: veins and pools
    w = fbm(wx * P["vein_scale"] * 10.0, wz * P["vein_scale"] * 10.0)
    ridge_n = np.clip(1.0 - np.abs(w * 2.0 - 1.0), 0, 1) ** P["vein_sharpness"]
    emit = VEIN[None, None, :] * (ridge_n * P["vein_strength"]
                                  * (1.0 - np.clip((slope - 0.3) / 0.4, 0, 1)))[..., None]
    wet = sample_mask(wx, wz)
    depth = np.clip((IMPASSABLE - h) / max(1e-3, IMPASSABLE), 0, 1)
    shore = np.clip((IMPASSABLE + 0.03 - h) / 0.08, 0, 1) * wet
    pick = np.clip((fbm(wx * 0.011 + 41.7, wz * 0.011 + 41.7) - 0.42) / 0.16, 0, 1)
    water = POOLG[None, None, :] + (POOLA - POOLG)[None, None, :] \
        * (pick * PAL_ALT)[..., None]
    emit = emit + water * (P["pool_glow_strength"] * shore
                           * (0.25 + 0.75 * depth))[..., None]

    base = base * (1.0 + tone)[..., None]

    if P["paint_quantise"] > 1.0 and paint > 0.0:
        base = np.floor(base * P["paint_quantise"] + 0.5) / P["paint_quantise"]

    # light(): banded lambert
    ndl = np.clip(np.sum(n * SUN[None, None, :], -1), 0, 1)
    lit = ndl
    if paint > 0.0 and P["paint_bands"] > 1.0:
        scaled = ndl * P["paint_bands"]
        step_i = np.floor(scaled)
        frac_v = scaled - step_i
        sm = np.clip((frac_v - 0.35) / 0.3, 0, 1)
        sm = sm * sm * (3 - 2 * sm)
        banded = (step_i + sm) / P["paint_bands"]
        lit = ndl + (banded - ndl) * paint
        seam = 1.0 - np.abs(frac_v - 0.5) * 2.0
        lit = lit * (1.0 - seam ** 8 * P["edge_ink"] * paint)

    out = base * (lit[..., None] * SUN_E + AMBIENT) + emit
    # grid
    if P["grid_spacing_m"] > 0.0:
        g = np.stack([wx, wz], -1) / P["grid_spacing_m"]
        line = np.max(1.0 - np.minimum(
            np.abs(g - np.floor(g) - 0.5) * 2.0 / 0.06, 1.0), -1)
        out = out + (GRID[None, None, :] - out) * (line * P["grid_strength"])[..., None]

    out = np.where((h < VOID)[..., None], CLOUD[None, None, :], out)
    return np.clip(out, 0, 1)


POOL, ROUGHC = rgb(PAL["pool"]), rgb(PAL["rough"])
GROUND, RIDGE, CLIFF = rgb(PAL["ground"]), rgb(PAL["ridge"]), rgb(PAL["cliff"])
POOLG = rgb(PAL["pool_glow"])
POOLA = rgb(PAL.get("pool_glow_alt", PAL["pool_glow"]))
VEIN = rgb(PAL["vein_glow"])
GRID = np.array([0.55, 0.88, 0.95])
CLOUD = np.array([0.42, 0.50, 0.58])
PAL_ALT = meta["surface"]["pool_alt_mix"]

# Sun and ambient stand in for the lighting rig. Approximate, and the only part
# of this that is not the shader's own arithmetic.
SUN = np.array([0.42, 0.80, -0.43])
SUN = SUN / np.linalg.norm(SUN)
SUN_E, AMBIENT = 1.45, 0.34

# Read from the export, not duplicated. An earlier version kept its own copy of
# every number and they had drifted apart within the hour, which makes the
# preview worse than useless — it disagrees with the game while claiming not to.
_p = meta["paint"]
_s = meta["surface"]
P = dict(stroke_scale=_p["stroke_scale"], stroke_stretch=_p["stroke_stretch"],
         stroke_depth=_p["stroke_depth"], paint_bands=_p["bands"],
         paint_quantise=_p["quantise"], edge_ink=_p["edge_ink"],
         paint_tone=_p["tone"],
         macro_scale=_s["macro_scale"], macro_strength=_s["macro_strength"],
         striation_strength=_s["striation"], vein_scale=_s["vein_scale"],
         vein_sharpness=_s["vein_sharpness"], vein_strength=_s["vein_strength"],
         pool_glow_strength=_s["pool_glow_strength"],
         grid_spacing_m=meta.get("grid_spacing_m", 0.0),
         grid_strength=_s["grid_strength"])
PAINT_ON = _p["strength"]

plain = render(0.0)
painted = render(PAINT_ON)
gap = np.ones((plain.shape[0], 8, 3)) * 0.1
img = np.concatenate([plain, gap, painted], 1)

# Written with bpy, because this venv has numpy but no PIL.
import bpy  # noqa: E402
H, W = img.shape[:2]
im = bpy.data.images.new("paint", width=W, height=H, alpha=False)
flat = np.concatenate([img[::-1], np.ones((H, W, 1))], -1).astype(np.float32)
im.pixels.foreach_set(flat.ravel())
im.filepath_raw = os.path.abspath(OUT)
im.file_format = 'PNG'
im.save()
print("PY: wrote %s  (%dx%d)  left: no paint, right: paint_strength %.2f"
      % (OUT, W, H, PAINT_ON))
