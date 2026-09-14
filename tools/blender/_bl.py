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
