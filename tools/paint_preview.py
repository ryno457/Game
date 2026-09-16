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
_mpath = os.path.join(DATA, "biodome_01_mat.u8")
matmap = (np.fromfile(_mpath, dtype=np.uint8).reshape(CZ, CX)
          if os.path.exists(_mpath) else np.zeros((CZ, CX), np.uint8))
_fpath = os.path.join(DATA, "biodome_01_fields.u8")
fields = (np.fromfile(_fpath, dtype=np.uint8).reshape(CZ, CX, 3).astype(np.float32) / 255.0
          if os.path.exists(_fpath) else np.zeros((CZ, CX, 3), np.float32))
_spath = os.path.join(DATA, "biodome_01_shade.u8")
shade = (np.fromfile(_spath, dtype=np.uint8).reshape(CZ, CX, 3).astype(np.float32) / 255.0
         if os.path.exists(_spath) else
         np.stack([np.ones((CZ, CX), np.float32), np.ones((CZ, CX), np.float32),
                   np.full((CZ, CX), 0.5, np.float32)], -1))
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


BRUSH = None


def load_brush(path="textures/brush_strokes.png"):
    """The same sheet the shader samples, read back as an array."""
    global BRUSH
    import bpy
    if not os.path.exists(path):
        return None
    im = bpy.data.images.load(os.path.abspath(path))
    w, h = im.size
    buf = np.empty(w * h * 4, np.float32)
    im.pixels.foreach_get(buf)
    BRUSH = buf.reshape(h, w, 4)[::-1]
    return BRUSH


def sample_brush(u, v):
    """Wrapped bilinear, matching repeat_enable + filter_linear."""
    h, w = BRUSH.shape[:2]
    x = (u * w) % w
    y = (v * h) % h
    x0, y0 = np.floor(x).astype(int) % w, np.floor(y).astype(int) % h
    x1, y1 = (x0 + 1) % w, (y0 + 1) % h
    fx, fy = (x - np.floor(x))[..., None], (y - np.floor(y))[..., None]
    return (BRUSH[y0, x0] * (1 - fx) * (1 - fy) + BRUSH[y0, x1] * fx * (1 - fy)
            + BRUSH[y1, x0] * (1 - fx) * fy + BRUSH[y1, x1] * fx * fy)


def sample_fields(wx, wz):
    """Bilinear, matching the shader's filter_linear on field_map.

    Nearest was wrong here in a way that mattered: the tube shading takes a
    central difference of this channel, and a nearest sample makes that
    difference zero inside a cell and a cliff at the boundary — a staircase
    crest the game will not have.
    """
    x = np.clip(wx, 0, CX - 1.001)
    z = np.clip(wz, 0, CZ - 1.001)
    x0, z0 = np.floor(x).astype(int), np.floor(z).astype(int)
    x1, z1 = np.minimum(x0 + 1, CX - 1), np.minimum(z0 + 1, CZ - 1)
    fx, fz = (x - x0)[..., None], (z - z0)[..., None]
    return (fields[z0, x0] * (1 - fx) * (1 - fz) + fields[z0, x1] * fx * (1 - fz)
            + fields[z1, x0] * (1 - fx) * fz + fields[z1, x1] * fx * fz)


def sample_shade(wx, wz):
    """R = AO, G = cast shadow, B = wide curvature. Bilinear, as the shader."""
    x = np.clip(wx, 0, CX - 1.001)
    z = np.clip(wz, 0, CZ - 1.001)
    x0, z0 = np.floor(x).astype(int), np.floor(z).astype(int)
    x1, z1 = np.minimum(x0 + 1, CX - 1), np.minimum(z0 + 1, CZ - 1)
    fx, fz = (x - x0)[..., None], (z - z0)[..., None]
    return (shade[z0, x0] * (1 - fx) * (1 - fz) + shade[z0, x1] * fx * (1 - fz)
            + shade[z1, x0] * (1 - fx) * fz + shade[z1, x1] * fx * fz)


def sample_mat(wx, wz):
    x = np.clip(wx, 0, CX - 1.001).astype(int)
    z = np.clip(wz, 0, CZ - 1.001).astype(int)
    return matmap[z, x].astype(int)


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
    # Material. Nearest lookup with a jittered sample position, exactly as the
    # shader does it: a blurred lookup would return an index halfway between
    # rock and moss, which is not a material.
    jx = fbm(wx * JSCALE, wz * JSCALE) - 0.5
    jz = fbm(wx * JSCALE + 9.13, wz * JSCALE + 9.13) - 0.5
    mi = np.clip(sample_mat(wx + jx * JITTER, wz + jz * JITTER), 0, 4)
    blend = np.clip(fbm(wx * 0.22, wz * 0.22), 0, 1)[..., None]
    base = MAT_COL[mi] + (MAT_ALT[mi] - MAT_COL[mi]) * blend

    # Height still has a say, but only where it means something.
    base = np.where((h < IMPASSABLE)[..., None], base + (POOL - base) * 0.80, base)
    hi = np.clip((h - 0.62) / 0.34, 0, 1)[..., None] * 0.55
    base = np.where((h > ROUGH)[..., None], base + (RIDGE - base) * hi, base)

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
        size = P["stroke_scale"] * MAT_STROKE[mi]
        spx, spz = wx * size, wz * size
        rx = spx * along[..., 0] + spz * along[..., 1]
        rz = (spx * down[..., 0] + spz * down[..., 1]) * P["stroke_stretch"]
        b = sample_brush(rx, rz)
        tone = (b[..., 0] - 0.5) * P["paint_tone"] * paint
        weave = sample_brush(wx * 0.9, wz * 0.9)[..., 3]
        tone = tone + (weave - 0.5) * P["canvas_grain"] * paint
        dx = (b[..., 1] - 0.5) * 2.0
        dz = (b[..., 2] - 0.5) * 2.0
        bend = along * dx[..., None] + down * dz[..., None]
        n = normalize(n + np.stack([bend[..., 0], np.zeros_like(h), bend[..., 1]], -1)
                      * P["stroke_depth"] * paint)

    slope = 1.0 - np.clip(n[..., 1], 0.0, 1.0)

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
    vein_here = P["vein_strength"] * MAT_VEIN[mi]
    emit = VEIN[None, None, :] * (ridge_n * vein_here
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

    # Distance gradients — exponential shoulders off the baked fields. This is
    # the part that replaces posterised bands with smooth falloff.
    draw = sample_fields(wx, wz)
    # R and B are plain distances; G is SIGNED over its own shorter range —
    # positive outside a root strand, zero at its edge, negative toward its
    # centreline. See TerrainBuilder.bake_fields for why it needs an inside.
    dist = np.stack([draw[..., 0] * P["field_range_m"],
                     (draw[..., 1] * 2.0 - 1.0) * P["strand_range_m"],
                     draw[..., 2] * P["field_range_m"]], -1)
    if P["edge_shade"] > 0:
        base = base * (1.0 - np.exp(-dist[..., 0] / max(0.01, P["edge_falloff_m"]))
                       * P["edge_shade"])[..., None]
    if P["strand_shade"] > 0:
        base = base * (1.0 - np.exp(-np.maximum(dist[..., 1], 0.0)
                                    / max(0.01, P["strand_falloff_m"]))
                       * P["strand_shade"])[..., None]
    if P["shore_pale"] > 0:
        t = (np.exp(-dist[..., 2] / max(0.01, P["shore_falloff_m"]))
             * P["shore_pale"])[..., None]
        base = base + (base * 1.35 + 0.06 - base) * t

    # Root strands as rounded tubes. In the reference a root is not a green
    # line painted on the floor, it is a tube: lit along its crest, shadowed at
    # its base. That is a normal, not a colour, so it goes in before the light.
    if P["tube_radius_m"] > 0.0:
        dg = dist[..., 1]
        inside = dg < 0.0
        # t: 1 at the strand's edge, 0 at its crest. The section rises from
        # nothing at the rim to full height at the centreline.
        tt = np.clip(1.0 + dg / max(1e-4, P["tube_radius_m"]), 0.0, 1.0)
        crest = np.sqrt(np.maximum(0.0, 1.0 - tt * tt))
        gx = (sample_fields(wx + 1.0, wz)[..., 1]
              - sample_fields(wx - 1.0, wz)[..., 1])
        gz = (sample_fields(wx, wz + 1.0)[..., 1]
              - sample_fields(wx, wz - 1.0)[..., 1])
        away = np.stack([gx, gz], -1)
        glen = np.linalg.norm(away, axis=-1, keepdims=True)
        away = np.where(glen > 1e-4, away / np.maximum(glen, 1e-9), 0.0)
        tube_n = normalize(np.stack([away[..., 0] * tt,
                                     np.maximum(crest, 0.08),
                                     away[..., 1] * tt], -1))
        k = (P["tube_blend"] * crest * inside)[..., None]
        n = normalize(n + (tube_n - n) * k)
        slope = 1.0 - np.clip(n[..., 1], 0.0, 1.0)

    # --- painted light: AO, cast shadow, curvature -------------------------
    sh = sample_shade(wx, wz)
    ao = 1.0 + (sh[..., 0] - 1.0) * L["ao_strength"]
    cast_shadow = 1.0 + (sh[..., 1] - 1.0) * L["shadow_strength"]
    # Undo bake_shade's signed-sqrt compander.
    we = sh[..., 2] * 2.0 - 1.0
    wide = np.sign(we) * we * we * L["curv_range"]
    lap = (sample_h(wx - 1.0, wz) + sample_h(wx + 1.0, wz)
           + sample_h(wx, wz - 1.0) + sample_h(wx, wz + 1.0) - 4.0 * h)
    fine = lap * HS
    curv = np.clip((wide * 0.65 + fine * 0.45) * L["curv_gain"], -1.0, 1.0)
    crease = np.maximum(curv, 0.0)
    base = base * (1.0 - crease * crease * L["crease_ink"])[..., None]
    v_shade = (1.0 + (ao - 1.0) * L["ao_light_affect"]) * cast_shadow

    if P["paint_quantise"] > 1.0 and paint > 0.0:
        base = np.floor(base * P["paint_quantise"] + 0.5) / P["paint_quantise"]

    # light(): the gradient map. Half-Lambert into a 1D ramp, biased by
    # curvature, exactly as terrain_lit.gdshader does it.
    ndl_raw = np.sum(n * SUN[None, None, :], -1)
    t = np.clip(ndl_raw * 0.5 + 0.5, 0, 1) ** L["terminator_k"]
    t = t * v_shade
    t = np.clip(t + np.maximum(-curv, 0.0) * 0.15
                - np.maximum(curv, 0.0) * 0.25, 0, 1)
    tone = ramp_lookup(t)
    tone = np.stack([t, t, t], -1) + (tone - np.stack([t, t, t], -1)) \
        * L["tone_ramp_strength"]

    out = base * tone * SUN_E + base * AMBIENT * ao[..., None] + emit
    if L["ridge_gain"] > 0.0:
        ridge = np.maximum(-curv, 0.0)
        out = out + RIDGE_TINT[None, None, :] * (
            ridge * ridge * L["ridge_gain"]
            * np.maximum(ndl_raw, 0.0) * v_shade)[..., None]
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
MATS = meta["materials"]
MAT_COL = np.stack([rgb(m["colour"]) for m in MATS])
MAT_ALT = np.stack([rgb(m["colour_alt"]) for m in MATS])
MAT_VEIN = np.array([m["vein"] for m in MATS])
MAT_STROKE = np.array([m["stroke"] for m in MATS])
INK = meta["paint"].get("ink_strength", 0.0)
INK_COL = rgb(meta["paint"].get("ink_colour", "050d0f"))
INK_SIL = meta["paint"].get("ink_silhouette", 0.02)
INK_CREASE = meta["paint"].get("ink_crease", 0.006)
GRID = np.array([0.55, 0.88, 0.95])
CLOUD = np.array([0.42, 0.50, 0.58])
PAL_ALT = meta["surface"]["pool_alt_mix"]

# Sun and ambient stand in for the lighting rig. Approximate, and the only part
# of this that is not the shader's own arithmetic.
# SUN comes from the palette's own two angles, below, so the preview's
# highlights land where the baked cast shadows say they should. SUN_E and
# AMBIENT stand in for the lighting rig and are the only numbers on this page
# that are not the shader's or the bake's own.
SUN_E, AMBIENT = 1.30, 0.30

# Read from the export, not duplicated. An earlier version kept its own copy of
# every number and they had drifted apart within the hour, which makes the
# preview worse than useless — it disagrees with the game while claiming not to.
_p = meta["paint"]
_s = meta["surface"]
# Read, not duplicated. This one WAS duplicated and had drifted: the shader had
# been retuned and the preview was still jittering at the old amplitude, which
# is the exact failure this file's header warns about.
JITTER = _s.get("material_jitter_m", 1.8)
JSCALE = _s.get("material_jitter_scale", 1.1)
P = dict(stroke_scale=_p["stroke_scale"], stroke_stretch=_p["stroke_stretch"],
         stroke_depth=_p["stroke_depth"],
         paint_quantise=_p["quantise"],
         paint_tone=_p["tone"], canvas_grain=_p.get("canvas_grain", 0.0),
         macro_scale=_s["macro_scale"], macro_strength=_s["macro_strength"],
         striation_strength=_s["striation"], vein_scale=_s["vein_scale"],
         vein_sharpness=_s["vein_sharpness"], vein_strength=_s["vein_strength"],
         pool_glow_strength=_s["pool_glow_strength"],
         grid_spacing_m=meta.get("grid_spacing_m", 0.0),
         grid_strength=_s["grid_strength"],
         field_range_m=_p.get("field_range_m", 20.0),
         edge_shade=_p.get("edge_shade", 0.0),
         edge_falloff_m=_p.get("edge_falloff_m", 9.0),
         strand_shade=_p.get("strand_shade", 0.0),
         strand_falloff_m=_p.get("strand_falloff_m", 3.0),
         shore_pale=_p.get("shore_pale", 0.0),
         shore_falloff_m=_p.get("shore_falloff_m", 7.0),
         strand_range_m=_p.get("strand_range_m", 4.0),
         tube_radius_m=_p.get("tube_radius_m", 0.0),
         tube_blend=_p.get("tube_blend", 0.8))
PAINT_ON = _p["strength"]

# The shading model. Kept separate from P because it is a model, not a palette.
_l = meta.get("light", {})
L = dict(terminator_k=_l.get("terminator_k", 1.0),
         tone_ramp_strength=_l.get("tone_ramp_strength", 0.0),
         ao_strength=_l.get("ao_strength", 0.0),
         ao_light_affect=_l.get("ao_light_affect", 0.0),
         shadow_strength=_l.get("shadow_strength", 0.0),
         curv_gain=_l.get("curv_gain", 0.0),
         crease_ink=_l.get("crease_ink", 0.0),
         ridge_gain=_l.get("ridge_gain", 0.0),
         curv_range=_p.get("curv_range", 3.0))
RIDGE_TINT = rgb(_l.get("ridge_tint", "ffffff"))

# The sun, from the same two angles the bake used — so the preview's highlights
# land where the baked cast shadows say they should. Azimuth is clockwise from
# -Z, matching TerrainBuilder.bake_shade.
_az = math.radians(_l.get("sun_azimuth_deg", -50.0))
_el = math.radians(_l.get("sun_elevation_deg", 58.0))
SUN = np.array([math.sin(_az) * math.cos(_el), math.sin(_el),
                -math.cos(_az) * math.cos(_el)])
SUN = SUN / np.linalg.norm(SUN)

# The gradient map, rebuilt from the exported stops. GradientTexture1D is a
# piecewise-linear interpolation of the stops, and np.interp is the same thing.
_ramp_off = np.array(_l.get("ramp_offsets", [0.0, 1.0]), np.float32)
_ramp_col = np.stack([rgb(c) for c in _l.get("ramp_colours", ["000000", "ffffff"])]) \
    if _l.get("ramp_colours") else np.stack([rgb("000000"), rgb("ffffff")])


def ramp_lookup(t):
    """Sample the tone ramp. Linear between stops, clamped at the ends."""
    return np.stack([np.interp(t, _ramp_off, _ramp_col[:, i]) for i in range(3)], -1)


load_brush()
if BRUSH is None:
    raise SystemExit("no brush sheet — run tools/make_brush_texture.py first")


def ink(img, h):
    """The ink pass, on height.

    From a straight-down orthographic camera the depth buffer IS the terrain
    height, so the same first- and second-difference tests the outline shader
    runs on depth can run on height here. Not identical to the game — the game
    also inks the props, which this has none of — but the same arithmetic on
    the same ground.
    """
    if INK <= 0.0:
        return img
    d = -h * HS
    dl, dr = np.roll(d, 1, 1), np.roll(d, -1, 1)
    du, dd = np.roll(d, 1, 0), np.roll(d, -1, 0)
    span = max(abs(float(d.max() - d.min())), 1e-3)
    sil = np.maximum(np.maximum(np.abs(dl - d), np.abs(dr - d)),
                     np.maximum(np.abs(du - d), np.abs(dd - d))) / span
    crease = (np.abs(dl + dr - 2 * d) + np.abs(du + dd - 2 * d)) / span
    def ss(x, a, b):
        t = np.clip((x - a) / max(b - a, 1e-6), 0, 1)
        return t * t * (3 - 2 * t)
    # Thresholds come from the export, so this cannot drift from the shader.
    line = np.maximum(ss(sil, INK_SIL, INK_SIL * 2.4),
                      ss(crease, INK_CREASE, INK_CREASE * 3.0))
    line = np.clip(line * INK, 0, 1)[..., None]
    return img + (INK_COL[None, None, :] - img) * line


plain = render(0.0)
painted = render(PAINT_ON)
H0, W0 = plain.shape[:2]
hh = sample_h(np.linspace(0, CX - 1, W0)[None, :].repeat(H0, 0),
              np.linspace(0, CZ - 1, H0)[:, None].repeat(W0, 1))
painted = ink(painted, hh)
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
