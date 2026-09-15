"""Generate the tiling brush-stroke texture the terrain shader paints with.

    ~/.cache/blender-venv/bin/python tools/make_brush_texture.py textures

This is the FIRST texture asset in the project. Everything until now has been
procedural or flat colour, and the procedural stroke field it replaces cost
three fbm evaluations per fragment — twelve value-noise lookups, forty-eight
hash operations. One texture fetch is cheaper than that AND looks like a brush
rather than like noise, which is the unusual case of the better-looking option
also being the faster one.

CHANNEL LAYOUT, and the reason for it:
    R  the stroke value
    G  d(value)/dx, remapped to 0..1
    B  d(value)/dy, remapped to 0..1
    A  canvas grain — fine, isotropic, unrelated to the strokes

Packing the gradient in means the shader gets the value AND the slope it needs
to bend the normal from a SINGLE fetch. Computing the gradient in the shader
would need two more taps and put the fetch count back where it started.

Every stroke points along +X. The shader rotates the lookup per fragment so the
marks follow the terrain's contour, so the texture must not carry a direction
of its own.

Deterministic: one seeded generator, no timestamps. Rebuilding never changes it.
"""
import math
import os
import sys

import numpy as np

OUT_DIR = sys.argv[1] if len(sys.argv) > 1 else "textures"
SIZE = int(sys.argv[2]) if len(sys.argv) > 2 else 512
os.makedirs(OUT_DIR, exist_ok=True)

rng = np.random.default_rng(20260915)
field = np.zeros((SIZE, SIZE), np.float32)

yy, xx = np.mgrid[0:SIZE, 0:SIZE].astype(np.float32)


def stamp(cx, cy, length, width, strength, bristles):
    """One brush mark, wrapped at the edges so the sheet tiles."""
    # Wrapped distance, so a stroke crossing the edge comes back on the other
    # side. Without this the texture tiles with a seam straight through it.
    dx = (xx - cx + SIZE * 1.5) % SIZE - SIZE * 0.5
    dy = (yy - cy + SIZE * 1.5) % SIZE - SIZE * 0.5

    # A brush is not a rectangle: the body is full width and both ends taper.
    along = np.clip(1.0 - (np.abs(dx) / length) ** 3.0, 0.0, 1.0)
    across = np.clip(1.0 - (np.abs(dy) / width) ** 2.0, 0.0, 1.0)
    mark = along * across

    # Bristle streaks running the length of the mark. This is most of what
    # separates a brush stroke from an airbrush blob.
    streak = 0.78 + 0.22 * np.cos(dy * bristles + math.sin(cx * 0.031) * 3.0)
    # Load runs out toward the end of a stroke.
    load = 1.0 - 0.35 * np.clip((dx / length) * 0.5 + 0.5, 0.0, 1.0)
    return mark * streak * load * strength


# Three passes at different sizes: a few broad laid-in marks, then mid strokes,
# then fine detail over the top. A single size reads as corduroy.
for count, (lo_len, hi_len), (lo_w, hi_w), strength in (
        (26, (95.0, 190.0), (17.0, 30.0), 0.55),
        (70, (45.0, 110.0), (8.0, 17.0), 0.42),
        (150, (18.0, 55.0), (3.5, 8.0), 0.30)):
    for _ in range(count):
        field += stamp(rng.uniform(0, SIZE), rng.uniform(0, SIZE),
                       rng.uniform(lo_len, hi_len), rng.uniform(lo_w, hi_w),
                       rng.uniform(0.6, 1.0) * strength,
                       # Bristle FREQUENCY, in radians per pixel. The first
                       # pass used 0.55-1.5, a period of four to eleven pixels,
                       # and 246 strokes of that stacked into what looked like
                       # scan lines rather than bristles. A few streaks per
                       # stroke is what a loaded brush leaves.
                       rng.uniform(0.10, 0.34))

# Normalise to 0..1 around its own mean, so the shader's "value minus a half"
# is a real centre rather than wherever the stamping happened to land.
field -= field.mean()
peak = max(float(np.abs(field).max()), 1e-5)
field = np.clip(field / (peak * 0.75) * 0.5 + 0.5, 0.0, 1.0)

# Gradient, packed for the shader. np.gradient with wrap-around edges, because
# a gradient that does not tile puts a bright seam on every tile boundary.
gy, gx = np.gradient(np.pad(field, 1, mode="wrap"))
gx, gy = gx[1:-1, 1:-1], gy[1:-1, 1:-1]
gscale = max(float(np.abs(np.stack([gx, gy])).max()), 1e-5)
gx = np.clip(gx / gscale * 0.5 + 0.5, 0.0, 1.0)
gy = np.clip(gy / gscale * 0.5 + 0.5, 0.0, 1.0)

# Canvas grain: fine, isotropic, nothing to do with the strokes.
grain = rng.random((SIZE, SIZE)).astype(np.float32)
grain = (grain + np.roll(grain, 1, 0) + np.roll(grain, 1, 1)) / 3.0
grain = np.clip(grain * 0.9 + 0.05, 0.0, 1.0)

rgba = np.stack([field, gx, gy, grain], -1).astype(np.float32)

import bpy  # noqa: E402
im = bpy.data.images.new("brush", width=SIZE, height=SIZE, alpha=True,
                         float_buffer=False, is_data=True)
im.colorspace_settings.name = 'Non-Color'
im.pixels.foreach_set(rgba[::-1].ravel())
path = os.path.abspath(os.path.join(OUT_DIR, "brush_strokes.png"))
im.filepath_raw = path
im.file_format = 'PNG'
im.save()

# A greyscale of the value channel alone, because the RGBA sheet is
# unreadable by eye: R is the stroke, G and B are a packed gradient.
look = bpy.data.images.new("brush_look", width=SIZE, height=SIZE, alpha=False)
look.pixels.foreach_set(np.stack([field, field, field,
                                  np.ones_like(field)], -1)[::-1].ravel())
# Into build/, not textures/: it is a thing to look at, not an asset, and the
# phone build copies everything under textures/.
_look_dir = os.path.join("build", "brush")
os.makedirs(_look_dir, exist_ok=True)
look.filepath_raw = os.path.abspath(os.path.join(_look_dir, "brush_preview.png"))
look.file_format = 'PNG'
look.save()

print("PY: wrote %s  %dx%d  RGBA" % (path, SIZE, SIZE))
print("PY: value mean %.3f  min %.3f  max %.3f"
      % (field.mean(), field.min(), field.max()))
print("PY: gradient scale %.5f per texel" % gscale)
