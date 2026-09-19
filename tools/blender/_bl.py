"""Shared helpers so the Blender scripts run under either front end.

Two ways to run them:
    blender --background --python tools/blender/<script>.py -- <args>
    ~/.cache/blender-venv/bin/python tools/blender/<script>.py <args>

The second is the `bpy` PyPI module, which is how this project gets a current
Blender: download.blender.org is blocked by the egress policy here, but PyPI is
reachable. Same engine, no GUI — which is all a headless pipeline needs.
"""
import bpy
import sys


def script_args():
    """Args after `--` when launched by the Blender binary, else argv[1:]."""
    if "--" in sys.argv:
        return sys.argv[sys.argv.index("--") + 1:]
    return sys.argv[1:]


def render(scene):
    """Render, surviving a Blender built without OpenImageDenoise.

    The Ubuntu apt build ships without it and throws at render time rather than
    reporting it up front, so this retries once with denoising off instead of
    hardcoding it off everywhere and giving up the quality on builds that have
    it (bpy 5.x does).
    """
    try:
        bpy.ops.render.render(write_still=True)
        return True
    except RuntimeError as exc:
        if "OpenImageDenoise" not in str(exc):
            raise
        scene.cycles.use_denoising = False
        bpy.ops.render.render(write_still=True)
        return False


def cycles_cpu(scene, samples):
    scene.render.engine = 'CYCLES'
    scene.cycles.device = 'CPU'
    scene.cycles.samples = samples
    scene.cycles.use_denoising = True     # render() falls back if unsupported


def image_array(img):
    """An image datablock as a float H x W x channels array."""
    import numpy as np
    buf = np.empty(len(img.pixels), dtype=np.float32)
    img.pixels.foreach_get(buf)
    return buf.reshape(img.size[1], img.size[0], img.channels)


def footprint_mask(shape, colour_bake):
    """True where the biodome floor is, False in the off-map void.

    Every whole-map bake shares one unwrap, so the colour bake's silhouette is
    every other bake's silhouette. Worth a shared helper because getting it
    wrong is not obvious: the void is black, black reads as fully occluded or
    fully unlit, and a statistic taken over the whole image is then mostly a
    measure of how much of the texture is empty. That mistake has already been
    made once here, on the AO bake, where it turned a mean of 0.862 into 0.663.
    """
    import numpy as np
    img = bpy.data.images.load(colour_bake)
    c = image_array(img)[..., :3].mean(axis=2)
    bpy.data.images.remove(img)
    if c.shape != tuple(shape):
        # Nearest neighbour: this is a mask, and a filtered edge would blend
        # void into floor.
        yi = (np.arange(shape[0]) * c.shape[0] // shape[0]).clip(0, c.shape[0] - 1)
        xi = (np.arange(shape[1]) * c.shape[1] // shape[1]).clip(0, c.shape[1] - 1)
        c = c[yi][:, xi]
    return c > 0.02
