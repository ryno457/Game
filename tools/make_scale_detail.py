"""A tiling scale pattern: normal map plus ambient occlusion.

    ~/.cache/blender-venv/bin/python tools/make_scale_detail.py [size] [rows]

Writes:
    textures/scale_detail_n.png    tangent-space normal, OpenGL green-up
    textures/scale_detail_ao.png   the shadow under each scale's lip, in R

WHAT IT IS. Overlapping rounded scales in offset rows — the surface of a thing
that grew rather than a thing that was cast. The ground, the vines and the
alien structures all share it, which is the point: they are supposed to read as
one organism's landscape, and nothing says that faster than one skin.

It is a companion to make_rock_detail.py and works the same way, for the same
reason: this pattern is exactly describable, so a closed-form function gives a
better result in a second than a ten-minute bake off modelled geometry would.

TILING IS ASSERTED against the wrap's own neighbours. "The opposite edges
match" is wrong — in a tiling texture the last column sits next to the first
column of the NEXT copy, so they differ by one ordinary step. "The wrap step is
near the average step" is also wrong, and failed this pattern while it tiled
exactly: most of the image is smooth dome interior, so a wrap that cuts through
a row of lips beats the average by a mile. A seam is a step much larger than
the steps immediately beside it.
"""
import os
import sys

import numpy as np
from PIL import Image

SIZE = int(sys.argv[1]) if len(sys.argv) > 1 else 512
# How many scales fit across the tile. The tile covers `metres` of surface, so
# this and the caller's UV scale together decide how big one scale is.
ROWS = int(sys.argv[2]) if len(sys.argv) > 2 else 12
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_N = os.path.join(ROOT, "textures", "scale_detail_n.png")
OUT_AO = os.path.join(ROOT, "textures", "scale_detail_ao.png")


def _hash(ix, iy, px, py, seed):
    ix = np.mod(ix, px).astype(np.int64)
    iy = np.mod(iy, py).astype(np.int64)
    n = (ix * 374761393 + iy * 668265263 + seed * 1442695041) & 0x7FFFFFFF
    n = (n ^ (n >> 13)) * 1274126177 & 0x7FFFFFFF
    return ((n ^ (n >> 16)) & 0xFFFFFF) / float(0xFFFFFF)


def _vnoise(u, v, px, py, seed):
    x, y = u * px, v * py
    ix, iy = np.floor(x), np.floor(y)
    fx, fy = x - ix, y - iy
    fx = fx * fx * (3.0 - 2.0 * fx)
    fy = fy * fy * (3.0 - 2.0 * fy)
    a = _hash(ix, iy, px, py, seed)
    b = _hash(ix + 1, iy, px, py, seed)
    c = _hash(ix, iy + 1, px, py, seed)
    d = _hash(ix + 1, iy + 1, px, py, seed)
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def scales(u, v, rows, seed):
    """Height of a field of overlapping scales, and distance from each scale's
    own centre.

    ROWS LIE OVER ROWS. The first version took the tallest dome at each pixel,
    which sounds like overlap and is not: two domes of equal height meet at a
    ridge halfway between them, so a field of them tessellates into a honeycomb
    and reads as bubble wrap. Real scales have a FREE EDGE — the row in front
    covers the row behind, and you can see where it stops.

    So this is a painter's order, not a maximum: among the scales whose
    footprint covers a pixel, the one from the frontmost row wins outright, and
    it sits a step above whatever it covers. That step is the free edge.

    Every scale is tested against its neighbouring cells because a scale is
    wider than its own cell — that is what overlapping means, and taking only
    the owning cell clips every dome at the cell wall.
    """
    cols = rows
    best = np.zeros_like(u)
    best_d = np.full_like(u, 9.0)
    best_row = np.full_like(u, -99.0)
    y = v * rows
    x0 = u * cols
    for oy in (-1, 0, 1):
        for ox in (-1, 0, 1):
            row = np.floor(y) + oy
            # Every other row shifted half a scale across.
            x = x0 + np.where(np.mod(row, 2) == 0, 0.0, 0.5)
            col = np.floor(x) + ox
            jitter = _hash(col, row, cols, rows, seed)
            r = 0.60 + 0.14 * jitter
            dx = (x - (col + 0.5)) / r
            # The centre sits FORWARD in its own cell, so the dome's long tail
            # is the part that gets covered by the row in front of it.
            dy = (y - (row + 0.30)) / (r * 1.45)
            d = np.sqrt(dx * dx + dy * dy)
            covered = d < 1.0
            # Frontmost wins. `row` is monotonic in v, so a larger row is
            # nearer the viewer's "front" and lies on top.
            take = covered & (row > best_row)
            dome = np.sqrt(np.clip(1.0 - d * d, 0.0, 1.0))
            # 0.30 of the height is the step the scale stands proud by, so its
            # rim is a cliff rather than a fade — that is the free edge.
            hh = 0.30 + dome * 0.70
            best = np.where(take, hh, best)
            best_d = np.where(take, d, best_d)
            best_row = np.where(take, row, best_row)
    return best, best_d


def main() -> int:
    g = (np.arange(SIZE) + 0.5) / SIZE
    u, v = np.meshgrid(g, g)

    h, d = scales(u, v, ROWS, 17)
    # A second, finer field of scales inside the first, and a grain under both.
    h2, _ = scales(u * 1.0, v * 1.0, ROWS * 3, 41)
    h = h * 0.80 + h2 * 0.13 + _vnoise(u, v, SIZE // 8, SIZE // 8, 63) * 0.07
    h -= h.min()
    h /= max(1e-6, h.max())

    # Relief as a FRACTION of one scale's width, so the bump reads the same
    # whatever size the caller tiles it at.
    scale_w = 1.0 / ROWS
    relief = 0.26 * scale_w
    step = 1.0 / SIZE
    dx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * relief / (2.0 * step)
    dy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * relief / (2.0 * step)
    n = np.stack([-dx, dy, np.ones_like(dx)], -1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    img_n = ((n * 0.5 + 0.5) * 255.0).clip(0, 255).astype(np.uint8)

    # The shadow under each lip. `d` is distance from a scale's own centre, so
    # the darkest place is the gap where two scales meet — which is exactly
    # where a real occlusion sweep would put it, without the sweep.
    ao = np.clip(0.42 + (1.15 - d) * 0.95, 0.0, 1.0)
    ao = 0.38 + ao * 0.62
    img_ao = (np.stack([ao, ao, ao], -1) * 255.0).clip(0, 255).astype(np.uint8)

    os.makedirs(os.path.dirname(OUT_N), exist_ok=True)
    Image.fromarray(img_n).save(OUT_N)
    Image.fromarray(img_ao).save(OUT_AO)

    slope = np.degrees(np.arctan(np.hypot(dx, dy)))
    print("PY: %dx%d, %d scales across, relief %.3f of a scale's width"
          % (SIZE, SIZE, ROWS, 0.26))
    print("PY: median slope %.1f deg, 95th %.1f deg; AO %.2f-%.2f"
          % (np.median(slope), np.percentile(slope, 95), ao.min(), ao.max()))
    a = img_n.astype(int)
    # TILING, tested against the wrap's OWN NEIGHBOURS.
    #
    # Comparing the wrap step to the average step over the whole image looks
    # right and is not: this pattern is mostly smooth dome interior with
    # occasional sharp lips, so a wrap that happens to cut through lips
    # measures 1.9x the average while tiling exactly. What a seam actually is,
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
