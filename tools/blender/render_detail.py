"""Render the high-detail source scene itself, in Cycles.

    ~/.cache/blender-venv/bin/python tools/blender/render_detail.py [w] [h] [samples]

Writes build/shots/detail_<view>.png, one per view below.

WHAT THIS IS FOR, and what it is NOT. Every other picture of this project is
the GAME: tools/screenshot.sh takes a real frame out of Godot through the real
terrain shader, and that is the one that decides whether the art works. This
renders the thing the maps are baked FROM — the 1.2 million faces of vine tube,
subdivided ground and clump that get flattened into two 2048-pixel textures and
then never seen again.

So its value is diagnostic, not decorative: it is the only way to look at what
the bake is reading. A vine whose tube is inside out, a clump sunk through the
floor, a scale texture at the wrong size — all of those come out of the bake as
a slightly wrong normal map and are invisible from there on.

It is Cycles, not the game's renderer, and it says nothing about how the frame
will look on a phone. See CLAUDE.md: the previews have lied before, and the
rule since is that only a real engine frame counts.
"""
import json
import math
import os
import struct
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _bl import cycles_cpu, script_args, render        # noqa: E402
from mathutils import Vector                           # noqa: E402

argv = script_args()
W = int(argv[0]) if argv else 1280
H = int(argv[1]) if len(argv) > 1 else 720
SAMPLES = int(argv[2]) if len(argv) > 2 else 48
## Emission is capped at this for the preview only. See main().
EMISSION_CAP = 0.30

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BLEND = os.path.join(ROOT, "art", "detail_source.blend")
DATA = os.path.join(ROOT, "build", "biodome")
OUT = os.path.join(ROOT, "build", "shots")

# name, metres from the subject, degrees above the horizon, what it is for
VIEWS = [
    ("close", 2.6, 26.0, "one bundle of vines, at the scale the skin reads at"),
    ("patch", 9.0, 38.0, "a patch of mat, to see the three tiers separate"),
]


def rgb(hexs):
    return tuple(int(hexs[i:i + 2], 16) / 255.0 for i in (0, 2, 4)) + (1.0,)


def densest_vine_cell(meta):
    """Where to point the camera: the most root-mat-surrounded cell on the map.

    Not the middle, and not the landing site. The subject here is the vine mat,
    and the middle of this map is open water — a render of the thing that is
    not being tested is worse than no render, because it looks like a pass.
    """
    cx, cz = meta["cells_x"], meta["cells_z"]
    mat = open(os.path.join(DATA, "biodome_01_mat.u8"), "rb").read()
    vine = 4                      # GroundMaterials.VINE
    best, best_n = (cx // 2, cz // 2), -1
    r = 4
    for y in range(r, cz - r, 2):
        for x in range(r, cx - r, 2):
            if mat[y * cx + x] != vine:
                continue
            n = sum(1 for dy in range(-r, r + 1) for dx in range(-r, r + 1)
                    if mat[(y + dy) * cx + (x + dx)] == vine)
            if n > best_n:
                best_n, best = n, (x, y)
    return best, best_n


def height_at(h, cx, cz, x, y):
    xi = min(max(int(x), 0), cx - 2)
    yi = min(max(int(y), 0), cz - 2)
    fx, fy = x - xi, y - yi
    a, b = h[yi * cx + xi], h[yi * cx + xi + 1]
    c, d = h[(yi + 1) * cx + xi], h[(yi + 1) * cx + xi + 1]
    return (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy


def main() -> int:
    bpy.ops.wm.open_mainfile(filepath=BLEND)
    sc = bpy.context.scene

    # THE LOW-POLY HAS TO GO. bake_target is the one-vertex-per-metre mesh the
    # bake fires AT, carrying an empty image material; left visible it sits a
    # few centimetres under everything and renders as a grey sheet with the
    # detail poking through it.
    hidden = []
    for o in bpy.data.objects:
        if o.name.startswith("bake_target") or o.type == 'CURVE':
            o.hide_render = True
            hidden.append(o.name)

    # DAMP THE EMISSIVE TIER. One vine in six glows, at a strength tuned for a
    # bake that never reads it: the albedo pass is colour-only, so emission
    # does not enter ground_detail_c.png, and the normal pass is geometric. In
    # Cycles it burns out completely — the glowing vines came back as flat pale
    # slabs with every trace of their form gone, which is the opposite of what
    # a diagnostic render is for. Damped here and nowhere else: the shipped
    # maps are unaffected either way, and this is the only thing that looks at
    # this scene with a light in it.
    damped = 0
    for m in bpy.data.materials:
        if not m.use_nodes:
            continue
        for n in m.node_tree.nodes:
            inp = n.inputs.get("Emission Strength")
            if inp is not None and inp.default_value > EMISSION_CAP:
                inp.default_value = EMISSION_CAP
                damped += 1
    print("PY: damped %d emissive inputs to %.2f for the preview"
          % (damped, EMISSION_CAP))

    meta = json.load(open(os.path.join(DATA, "biodome_01.json")))
    cx, cz = meta["cells_x"], meta["cells_z"]
    hs = meta["height_scale_m"]
    with open(os.path.join(DATA, "biodome_01.r32"), "rb") as f:
        h = struct.unpack("<%df" % (cx * cz), f.read())
    (tx, ty), dens = densest_vine_cell(meta)
    tz = height_at(h, cx, cz, tx, ty) * hs
    print("PY: subject at cell (%d, %d), %d of 81 neighbours are root mat"
          % (tx, ty, dens))

    # The game's own moon, read from the same meta the previews use, so this
    # is at least lit by the light the map was tuned under.
    view = meta["view"]
    sun_data = bpy.data.lights.new("sun", 'SUN')
    sun_data.energy = float(view["sun_energy"]) * 3.2   # Cycles watts
    sun_data.color = rgb(view["sun_colour"])[:3]
    sun_data.angle = math.radians(float(view.get("sun_angular_deg", 1.0)))
    sun = bpy.data.objects.new("sun", sun_data)
    sc.collection.objects.link(sun)
    az = math.radians(float(view["sun_azimuth_deg"]))
    el = math.radians(float(view["sun_elevation_deg"]))
    # The source scene is Z-up and in map coordinates, so the game's azimuth
    # (clockwise from -Z, Y up) becomes a direction in X/Y/Z directly.
    toward = Vector((math.sin(az) * math.cos(el),
                     -math.cos(az) * math.cos(el),
                     math.sin(el)))
    sun.rotation_mode = 'QUATERNION'
    sun.rotation_quaternion = toward.to_track_quat('Z', 'Y')

    world = bpy.data.worlds.new("sky")
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs["Color"].default_value = rgb(view["sky_horizon"])
    bg.inputs["Strength"].default_value = float(view["ambient_energy"]) * 2.2
    sc.world = world

    cam_data = bpy.data.cameras.new("cam")
    cam_data.lens = 50.0
    cam = bpy.data.objects.new("cam", cam_data)
    sc.collection.objects.link(cam)
    sc.camera = cam

    cycles_cpu(sc, SAMPLES)
    sc.render.resolution_x = W
    sc.render.resolution_y = H
    sc.render.resolution_percentage = 100
    os.makedirs(OUT, exist_ok=True)

    target = Vector((tx, ty, tz + 0.25))
    for name, dist, pitch, why in VIEWS:
        a = math.radians(pitch)
        # Approach from the sun's own side minus 40 degrees, so the subject is
        # side-lit rather than flat-lit or in its own shadow.
        b = az - math.radians(40.0)
        cam.location = target + Vector((math.sin(b) * math.cos(a) * dist,
                                        -math.cos(b) * math.cos(a) * dist,
                                        math.sin(a) * dist))
        cam.rotation_mode = 'QUATERNION'
        cam.rotation_quaternion = (target - cam.location).to_track_quat('-Z', 'Y')
        path = os.path.join(OUT, "detail_%s.png" % name)
        sc.render.filepath = path
        sc.render.image_settings.file_format = 'PNG'
        render(sc)
        print("PY: wrote %s  (%s)" % (path, why))
    print("PY: hid %d objects from the render" % len(hidden))
    return 0


raise SystemExit(main())
