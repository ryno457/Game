"""A tiling rock surface: normal map plus ambient occlusion.

    ~/.cache/blender-venv/bin/python tools/make_rock_detail.py [size] [metres]

Writes:
    textures/rock_detail_n.png    tangent-space normal, OpenGL green-up
    textures/rock_detail_ao.png   cavity occlusion, single channel in R

WHY NOT A BLENDER BAKE. The ground's detail is baked off modelled geometry
because its detail IS geometry — vines, pores, clumps, things with a shape
somebody decided. Rock at half a metre is not that: it is fractal by nature and
the same everywhere, so modelling it would be modelling noise, and baking it
would be a ten-minute round trip for a result a closed-form function gives
exactly. This runs in about a second.

IT MUST TILE. The ravine wall is a 500 m ring sampled every 32 m, so a seam
would repeat sixteen times across the frame. The noise below is periodic by
construction — the lattice hash is taken modulo the period — rather than
mirrored or cross-faded, both of which leave a visible axis.

The normal is OpenGL convention (green points UP). Godot expects that; DirectX
maps (green down) come out lit from the wrong side, which reads as the surface
being inside out and is easy to mistake for a lighting bug.
"""
import os
import sys

import numpy as np
from PIL import Image

SIZE = int(sys.argv[1]) if len(sys.argv) > 1 else 512
# How many metres the tile covers. The ravine's UVs are world metres / 32, so
# this has to agree with that or the rock is the wrong size.
METRES = float(sys.argv[2]) if len(sys.argv) > 2 else 32.0
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_N = os.path.join(ROOT, "textures", "rock_detail_n.png")
OUT_AO = os.path.join(ROOT, "textures", "rock_detail_ao.png")


def _hash(ix, iy, period, seed):
    """Deterministic lattice hash, periodic in both axes."""
    ix = np.mod(ix, period).astype(np.int64)
    iy = np.mod(iy, period).astype(np.int64)
    n = (ix * 374761393 + iy * 668265263 + seed * 1442695041) & 0x7FFFFFFF
    n = (n ^ (n >> 13)) * 1274126177 & 0x7FFFFFFF
    return ((n ^ (n >> 16)) & 0xFFFFFF) / float(0xFFFFFF)


def vnoise(u, v, period, seed):
    x, y = u * period, v * period
    ix, iy = np.floor(x), np.floor(y)
    fx, fy = x - ix, y - iy
    fx = fx * fx * (3.0 - 2.0 * fx)
    fy = fy * fy * (3.0 - 2.0 * fy)
    a = _hash(ix, iy, period, seed)
    b = _hash(ix + 1, iy, period, seed)
    c = _hash(ix, iy + 1, period, seed)
    d = _hash(ix + 1, iy + 1, period, seed)
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def ridged(u, v, period, seed):
    """One octave folded about its midpoint, which is what turns a smooth swell
    into a CREASE. Rock is made of creases; a plain fbm gives dough."""
    return 1.0 - np.abs(vnoise(u, v, period, seed) * 2.0 - 1.0)


def main() -> int:
    g = (np.arange(SIZE) + 0.5) / SIZE
    u, v = np.meshgrid(g, g)

    # Four bands over five octaves of scale, in metres: slabs at 8 m, blocks at
    # 2 m, chips at 60 cm, grain at 15 cm. The ridged terms carry the creases
    # between blocks and the smooth ones carry the swell they sit on.
    h = (ridged(u, v, 4, 11) * 0.42
         + ridged(u, v, 16, 23) * 0.24
         + vnoise(u, v, 32, 37) * 0.18
         + ridged(u, v, 64, 51) * 0.10
         + vnoise(u, v, 128, 67) * 0.06)
    h -= h.min()
    h /= max(1e-6, h.max())

    # Height in metres, so the slope is a real slope rather than a knob.
    relief_m = 0.42
    step_m = METRES / SIZE
    hm = h * relief_m
    dx = (np.roll(hm, -1, 1) - np.roll(hm, 1, 1)) / (2.0 * step_m)
    dy = (np.roll(hm, -1, 0) - np.roll(hm, 1, 0)) / (2.0 * step_m)
    # Tangent space, OpenGL: +X right, +Y up, +Z out of the surface.
    n = np.stack([-dx, dy, np.ones_like(dx)], -1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    img_n = ((n * 0.5 + 0.5) * 255.0).clip(0, 255).astype(np.uint8)

    # CAVITY, not a real occlusion sweep. How far below its own neighbourhood a
    # texel sits, at two radii. A ray-traced AO over a tiling heightfield would
    # be more correct and would look the same at 15 cm; this is the cheap term
    # that actually describes "down in a crack".
    def blur(a, r):
        k = np.ones(2 * r + 1) / (2 * r + 1)
        a = np.apply_along_axis(lambda m: np.convolve(
            np.concatenate([m[-r:], m, m[:r]]), k, "same")[r:-r], 0, a)
        return np.apply_along_axis(lambda m: np.convolve(
            np.concatenate([m[-r:], m, m[:r]]), k, "same")[r:-r], 1, a)

    wide = blur(h, max(2, SIZE // 32))
    near = blur(h, max(1, SIZE // 128))
    cav = (h - wide) * 0.75 + (h - near) * 0.55
    ao = np.clip(0.5 + cav * 2.2, 0.0, 1.0)
    # Never fully black. An AO of zero in a crack turns the rock into a hole,
    # and on this rig ambient is small enough that it would stay a hole.
    ao = 0.34 + ao * 0.66
    img_ao = np.stack([ao, ao, ao], -1)
    img_ao = (img_ao * 255.0).clip(0, 255).astype(np.uint8)

    os.makedirs(os.path.dirname(OUT_N), exist_ok=True)
    Image.fromarray(img_n).save(OUT_N)
    Image.fromarray(img_ao).save(OUT_AO)
    slope = np.degrees(np.arctan(np.hypot(dx, dy)))
    print("PY: %dx%d over %.0f m, relief %.2f m" % (SIZE, SIZE, METRES, relief_m))
    print("PY: median slope %.1f deg, 95th %.1f deg; AO %.2f-%.2f"
          % (np.median(slope), np.percentile(slope, 95), ao.min(), ao.max()))
    # A map whose edges do not match is the one failure that is invisible until
    # it is on a 500 m wall, so it is asserted rather than eyeballed.
    #
    a = img_n.astype(int)
    # TILING, tested against the wrap's OWN NEIGHBOURS.
    #
    # Comparing the wrap step to the average step over the whole image looks
    # right and is not: a pattern with a few sharp features and a lot of
    # smooth ground beats or misses the average for reasons that have nothing
    # to do with seams. What a seam actually is,
    # is a step much larger than the steps immediately beside it — so that is
    # the comparison. A true tile lands near 1.0.
    def _wrap(arr, axis):
        edge = np.abs(np.take(arr, 0, axis) - np.take(arr, -1, axis)).mean()
        near = 0.5 * (np.abs(np.take(arr, 1, axis) - np.take(arr, 0, axis)).mean()
                      + np.abs(np.take(arr, -1, axis) - np.take(arr, -2, axis)).mean())
        return edge / max(1e-6, near)
    rx = _wrap(a, 1)
    ry = _wrap(a, 0)
    ok = rx < 1.5 and ry < 1.5
    print("PY: %s tiling — the wrap step is %.2fx / %.2fx the steps beside it"
          % ("ok  " if ok else "FAIL", rx, ry))
    print("PY: wrote %s\nPY: wrote %s" % (OUT_N, OUT_AO))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
