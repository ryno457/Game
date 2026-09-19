"""Render every model in a row, lit by the HDRI the game bakes from.

    ~/.cache/blender-venv/bin/python tools/blender/model_lineup.py [sky] [samples]

A sheet of what the props, machines and aliens actually look like under
night.exr — the same Poly Haven sky bake_sky.py uses on the terrain and
sky_light_scene() bakes into their vertex colours. Cycles, so this is the
reference the baked approximation is trying to be, not the approximation
itself.

The models are laid out on a ground plane in a single row, scaled to a common
height so a 0.6 m drone and a 9 m arch are both legible, and shot from the
game's own three-quarter angle rather than straight on.
"""
import glob
import math
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _ao import default_sky                                     # noqa: E402
from _bl import script_args                                     # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MODELS = os.path.join(ROOT, "models")
OUT = os.path.join(ROOT, "build", "hdri", "model_lineup.png")
SPACING = 3.0
TARGET_H = 2.0


def resolve(name):
    if os.path.exists(name):
        return os.path.abspath(name)
    p = os.path.join(bpy.utils.resource_path('LOCAL'), "datafiles",
                     "studiolights", "world", name + ".exr")
    assert os.path.exists(p), "no sky called %r" % name
    return p


def main():
    argv = script_args()
    sky = resolve(argv[0]) if argv else default_sky()
    samples = int(argv[1]) if len(argv) > 1 else 48

    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.engine = 'CYCLES'
    sc.cycles.device = 'CPU'
    sc.cycles.samples = samples
    sc.cycles.use_denoising = False
    sc.view_settings.view_transform = 'Standard'

    world = bpy.data.worlds.new("sky")
    sc.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    env = world.node_tree.nodes.new("ShaderNodeTexEnvironment")
    env.image = bpy.data.images.load(sky)
    world.node_tree.links.new(env.outputs["Color"], bg.inputs["Color"])
    # Lift the exposure: night.exr is a tenth of a daylight sky and the point
    # of the sheet is to see the models, not to reproduce the game's darkness.
    bg.inputs["Strength"].default_value = 6.0

    paths = sorted(glob.glob(os.path.join(MODELS, "*.glb")))
    n = len(paths)
    width = (n - 1) * SPACING
    for i, p in enumerate(paths):
        before = set(o.name for o in bpy.data.objects)
        bpy.ops.import_scene.gltf(filepath=p)
        fresh = [o for o in bpy.data.objects
                 if o.name not in before and o.type == 'MESH']
        if not fresh:
            continue
        # One common height, so a 0.6 m drone and a 9 m arch both read.
        lo = min(min((o.matrix_world @ v.co).z for v in o.data.vertices)
                 for o in fresh)
        hi = max(max((o.matrix_world @ v.co).z for v in o.data.vertices)
                 for o in fresh)
        scale = TARGET_H / max(0.01, hi - lo)
        x = -width * 0.5 + i * SPACING
        for o in fresh:
            o.scale = (scale, scale, scale)
            o.location = (o.location.x * scale + x,
                          o.location.y * scale,
                          (o.location.z - lo) * scale)

    ground = bpy.ops.mesh.primitive_plane_add(size=width + 12.0,
                                              location=(0, 0, 0))
    plane = bpy.context.object
    m = bpy.data.materials.new("ground")
    m.use_nodes = True
    m.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (
        0.05, 0.08, 0.075, 1.0)
    plane.data.materials.append(m)

    cam_data = bpy.data.cameras.new("cam")
    cam = bpy.data.objects.new("cam", cam_data)
    sc.collection.objects.link(cam)
    sc.camera = cam
    # The game's own three-quarter view, far enough back to hold the row.
    cam.location = (0.0, -(width * 0.62 + 6.0), width * 0.30 + 5.0)
    cam.rotation_euler = (math.radians(66.0), 0.0, 0.0)
    cam_data.lens = 58.0

    sc.render.resolution_x = 2000
    sc.render.resolution_y = 420
    sc.render.filepath = OUT
    sc.render.image_settings.file_format = 'PNG'
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    print("PY: %d models, %s, %d samples" % (n, os.path.basename(sky), samples))
    bpy.ops.render.render(write_still=True)
    print("PY: wrote %s" % os.path.relpath(OUT, ROOT))


main()
