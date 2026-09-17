"""The biodome's canopy, as a light projector texture.

    ~/.cache/blender-venv/bin/python tools/make_canopy_cookie.py [size] [rings]

Writes:
    textures/canopy_cookie.png    greyscale transmission; dark ribs, lit panels

WHAT A COOKIE IS. A texture a light looks THROUGH. Godot calls the slot
`light_projector`; every other trade calls it a gobo. The light's colour is
multiplied by it before any shading happens, so it costs one texture fetch
inside a light loop that was already running and buys the single most valuable
thing a flat moonlit floor is missing: a reason for one patch of ground to be
brighter than the next.

WHY IT FITS THIS GAME RATHER THAN BEING A NICE EFFECT. The design brief says
the player is inside a SEALED BIODOME. Nothing in the frame has ever said so —
the map reads as open ground under a night sky. A hex lattice of structural
ribs thrown across the floor says "there is a roof on this" in the one way that
costs no geometry, no draw call and no extra triangle: it is the shadow of a
thing that does not have to exist.

SPOT, NOT DIRECTIONAL. Verified against the engine's own shader code in 4.7.2:
`projector_rect` appears for spot, omni and area lights and NOWHERE for
directional. The moon cannot carry this. See CanopyLight for what does.

IT TILES, and it has to. See CanopyLight: light_projector could not be made to
work on this machine, so the canopy is applied in the terrain shader in world
space instead, which samples it repeating across the map. The lattice is
periodic by construction and the wrap is asserted below.
"""
import math
import os
import sys

import numpy as np
from PIL import Image

SIZE = int(sys.argv[1]) if len(sys.argv) > 1 else 1024
## Hex cells across the texture. The projector covers the whole playable map,
## so this over the map's width is how big one panel is on the ground.
RINGS = int(sys.argv[2]) if len(sys.argv) > 2 else 9
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "textures", "canopy_cookie.png")


def _hash(ix, iy, seed=0, px=1 << 20, py=1 << 20):
    """Periodic lattice hash. The modulo is what lets the pattern TILE: cell
    -1 and cell (cells - 1) have to be the same cell or the wrap is a seam."""
    ix = np.mod(ix, px).astype(np.int64)
    iy = np.mod(iy, py).astype(np.int64)
    n = (ix * 374761393 + iy * 668265263
         + seed * 1442695041) & 0x7FFFFFFF
    n = (n ^ (n >> 13)) * 1274126177 & 0x7FFFFFFF
    return ((n ^ (n >> 16)) & 0xFFFFFF) / float(0xFFFFFF)


def hex_field(u, v, cells, rows):
    """Distance to the nearest two hex centres, and the nearest one's id.

    The RIB is where the two are equal — that is the definition of a cell
    boundary, and taking it from a two-nearest test rather than from an
    analytic hexagon means the lattice can be perturbed later without the
    formula stopping being true.

    Pointy-top hexagons on a staggered lattice: rows are offset half a cell,
    and the row pitch is sqrt(3)/2 of the column pitch, which is what makes
    the cells regular rather than squashed.
    """
    x = u * cells
    y = v * rows
    row = np.floor(y)
    d1 = np.full(u.shape, 1e9)
    d2 = np.full(u.shape, 1e9)
    id_x = np.zeros(u.shape)
    id_y = np.zeros(u.shape)
    for dy in (-1, 0, 1):
        r = row + dy
        off = np.where(np.mod(r, 2) == 0, 0.0, 0.5)
        for dx in (-1, 0, 1, 2):
            c = np.floor(x - off) + dx
            cxp = c + off + 0.5
            cyp = r + 0.5
            d = np.hypot((x - cxp) / cells, (y - cyp) / rows)
            nearer = d < d1
            d2 = np.where(nearer, d1, np.minimum(d2, d))
            id_x = np.where(nearer, c, id_x)
            id_y = np.where(nearer, r, id_y)
            d1 = np.where(nearer, d, d1)
    return d1, d2, id_x, id_y


def main() -> int:
    g = (np.arange(SIZE) + 0.5) / SIZE
    u, v = np.meshgrid(g, g)
    # ROWS MUST BE EVEN, or the half-cell row offset does not survive the wrap
    # and the top edge meets the bottom edge half a hexagon out. Rounded to the
    # nearest even number from the pitch that keeps the cells regular.
    rows = max(2, int(round(RINGS / (math.sqrt(3.0) / 2.0) / 2.0)) * 2)
    d1, d2, ix, iy = hex_field(u, v, RINGS, rows)

    # THE RIBS. Where the two nearest centres are within a hair of each other.
    edge = d2 - d1
    rib = 1.0 - np.clip(edge / (0.55 / RINGS), 0.0, 1.0)
    rib = rib ** 1.8
    # A thinner, brighter line down the middle of each rib: a structural member
    # seen from below is lit on its own underside by everything around it, and
    # a rib that is only a dark gap reads as a crack instead of a beam.
    spine = np.clip(1.0 - edge / (0.16 / RINGS), 0.0, 1.0) ** 2.6

    # THE PANELS. Each one its own transmission, so the canopy reads as a built
    # thing that has weathered rather than as a pattern.
    grime = _hash(ix, iy, 11, RINGS, rows)
    panel = 0.58 + 0.42 * grime
    # One panel in nine is gone. That is where the brightest light on the map
    # falls, and it is worth more than any amount of even illumination: a floor
    # lit evenly has nowhere the eye wants to go.
    broken = _hash(ix, iy, 29, RINGS, rows) > 0.89
    panel = np.where(broken, 1.0, panel)
    # And a soft gradient across each panel, from the rib inward, so a panel is
    # not a flat chip of light.
    panel *= 0.82 + 0.18 * np.clip(edge * RINGS * 4.0, 0.0, 1.0)

    light = panel * (1.0 - rib * 0.88) + spine * 0.22
    # NO BORDER FADE. The first version faded the edge to the mean, which is
    # right for a projector thrown once through a cone and exactly wrong here:
    # this tiles across the world, so a border treatment IS the seam. The
    # lattice is periodic instead — see _hash and the even row count.
    light = np.clip(light, 0.0, 1.0)

    img = (np.stack([light] * 3, -1) * 255.0).clip(0, 255).astype(np.uint8)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    Image.fromarray(img).save(OUT)
    print("PY: %dx%d, %d hex cells across" % (SIZE, SIZE, RINGS))
    print("PY: transmission %.2f-%.2f, mean %.2f; %.0f%% of area is rib"
          % (light.min(), light.max(), light.mean(), 100 * np.mean(rib > 0.5)))
    print("PY: %.0f%% of panels are broken open" % (100 * np.mean(broken)))
    a = img.astype(int)

    def _wrap(arr, axis):
        edge_d = np.abs(np.take(arr, 0, axis) - np.take(arr, -1, axis)).mean()
        near = 0.5 * (np.abs(np.take(arr, 1, axis) - np.take(arr, 0, axis)).mean()
                      + np.abs(np.take(arr, -1, axis) - np.take(arr, -2, axis)).mean())
        return edge_d / max(1e-6, near)
    rx, ry = _wrap(a, 1), _wrap(a, 0)
    ok = rx < 1.5 and ry < 1.5
    print("PY: %s tiling — the wrap step is %.2fx / %.2fx the steps beside it"
          % ("ok  " if ok else "FAIL", rx, ry))
    print("PY: wrote %s" % OUT)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
