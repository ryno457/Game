"""The high-detail source scene, and the maps baked out of it.

    ~/.cache/blender-venv/bin/python tools/blender/detail_source.py [res_x] [vines]

Writes:
    art/detail_source.blend         the editable high-detail scene
    textures/ground_detail_n.png    tangent-space normal, baked with a cage
    textures/ground_detail_c.png    albedo

WHOLE MAP, NOT A TILE. This used to bake a 26.8 m tile that the shader repeated,
because the ground could be dug and a deformable surface cannot hold a UV
unwrap. Deformation is now out of the design, and that changes the right answer
completely: the terrain is a fixed shape, so it can carry a real unwrap and the
whole 150 x 112 m map can be baked ONCE into one texture.

Nothing repeats, so there is no tiling to hide. That is not a tuning of the old
approach, it is the removal of the problem.

The unwrap needs no seams and no packing: the terrain is a heightfield, so
(x / width, z / depth) is already an injective UV over the whole surface, and it
is the SAME mapping the shader's existing field maps use. So the bake lands in
the coordinate system the game is already sampling.

THE CAGE. Vines sit above the ground, so bake rays must start above them and
travel down. `cage_extrusion` pushes the low-poly outward along its own normals
to launch from; too small and the tops of the vines are missed, too large and a
ray from one side of a ridge reaches geometry on the other. CAGE_M is set from
the tallest vine plus a margin, not guessed.
"""
import math
import os
import random
import struct
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _bl import cycles_cpu, script_args          # noqa: E402
from build_flora import MB, hexcol, make_object  # noqa: E402

argv = script_args()
RES_X = int(argv[0]) if argv else 2048
VINE_TARGET = int(argv[1]) if len(argv) > 1 else 520
SEED = 20260916

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DATA = os.path.join(ROOT, "build", "biodome")
BLEND = os.path.join(ROOT, "art", "detail_source.blend")
OUT_N = os.path.join(ROOT, "textures", "ground_detail_n.png")
OUT_C = os.path.join(ROOT, "textures", "ground_detail_c.png")

# Sampled from docs/reference/01-vtt-cavern-map.jpg. NOTHING here is light grey:
# that value belongs to the machines, and a landscape that shares it hides them.
GROUND_MID = "1f3d3c"
VINE_BODY = "39605e"       # the pale structural tube: the dominant web
LIVE_BODY = "367141"       # the glowing emerald roots: a small MINORITY
GLOW = "68d9aa"

VINE_MAT = 4               # GroundMaterials.VINE
CAGE_M = 1.4               # tallest vine ~0.9 m, plus margin


def _mat(name, hexs, rough=0.85, emit=None, emit_w=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = hexcol(hexs)
    b.inputs["Roughness"].default_value = rough
    if emit is not None and "Emission Color" in b.inputs:
        b.inputs["Emission Color"].default_value = hexcol(emit)
        b.inputs["Emission Strength"].default_value = emit_w
    return m


def load_map():
    import json
    meta = json.load(open(os.path.join(DATA, "biodome_01.json")))
    cx, cz = meta["cells_x"], meta["cells_z"]
    with open(os.path.join(DATA, "biodome_01.r32"), "rb") as f:
        h = struct.unpack("<%df" % (cx * cz), f.read())
    mat = open(os.path.join(DATA, "biodome_01_mat.u8"), "rb").read()
    return meta, cx, cz, h, mat


def terrain(cx, cz, h, hs, void, name, mats):
    """The map as a mesh, with the heightfield's own UV."""
    me = bpy.data.meshes.new(name + "_mesh")
    verts = [(x, z, h[z * cx + x] * hs) for z in range(cz) for x in range(cx)]
    faces = []
    for z in range(cz - 1):
        for x in range(cx - 1):
            q = (z * cx + x, z * cx + x + 1, (z + 1) * cx + x + 1, (z + 1) * cx + x)
            if void > 0.0 and any(h[i] < void for i in q):
                continue
            faces.append(q)
    me.from_pydata(verts, [], faces)
    me.update()
    for p in me.polygons:
        p.use_smooth = True
    # The unwrap. No seams, no packing, no overlap: a heightfield is a graph
    # over the XZ plane, so this is injective by construction.
    uv = me.uv_layers.new(name="UVMap")
    for loop in me.loops:
        v = me.vertices[loop.vertex_index].co
        uv.data[loop.index].uv = (v.x / (cx - 1.0), v.y / (cz - 1.0))
    for m in mats:
        me.materials.append(m)
    ob = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(ob)
    return ob


def height_at(h, cx, cz, x, y):
    xi = min(max(int(x), 0), cx - 2)
    yi = min(max(int(y), 0), cz - 2)
    fx, fy = x - xi, y - yi
    a, b = h[yi * cx + xi], h[yi * cx + xi + 1]
    c, d = h[(yi + 1) * cx + xi], h[(yi + 1) * cx + xi + 1]
    return (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy


def vine_run(rng, h, cx, cz, hs, x0, y0, length, width):
    """One vine, following the ground, wandering and swelling along its length."""
    pts, radii = [], []
    x, y = x0, y0
    ang = rng.uniform(0, math.tau)
    steps = max(5, int(length / 0.9))
    for i in range(steps):
        t = i / float(steps - 1)
        ang += rng.uniform(-0.40, 0.40)
        step = length / steps
        x += math.cos(ang) * step
        y += math.sin(ang) * step
        x = min(max(x, 1.0), cx - 2.0)
        y = min(max(y, 1.0), cz - 2.0)
        z = height_at(h, cx, cz, x, y) * hs
        pts.append((x, y, z + 0.04 + 0.10 * width))
        swell = 0.60 + 0.40 * math.sin(t * math.pi * rng.uniform(1.4, 3.4))
        ends = min(1.0, 3.2 * min(t, 1.0 - t) + 0.22)
        radii.append(width * swell * ends)
    return pts, radii


def build(rng, cx, cz, h, mat, hs, void):
    mats = [_mat("ground", GROUND_MID, 0.92),
            _mat("vine", VINE_BODY, 0.80),
            _mat("live", LIVE_BODY, 0.70, GLOW, 2.5)]

    low = terrain(cx, cz, h, hs, void, "bake_target", [mats[0]])
    high_ground = terrain(cx, cz, h, hs, void, "high_ground", [mats[0]])

    # DENSITY, and it follows the map rather than a noise field. The classifier
    # already decided which cells are root mat; vines are seeded only there, so
    # the web lands exactly where the game's own materials, pathing and
    # gameplay already say it is. That also means the patches are the map's
    # patches — nothing here has to invent where the clear ground goes.
    seeds = [i for i in range(cx * cz) if mat[i] == VINE_MAT]
    rng.shuffle(seeds)
    made = 0
    for i in seeds:
        if made >= VINE_TARGET:
            break
        # Thin the seeds so vines start spread out rather than all in the first
        # few cells the shuffle happened to pick.
        if rng.random() > 0.55:
            continue
        x0, y0 = i % cx, i // cx
        # A bundle, not a single vine: the reference's web is bundles of about
        # four crests inside a 3.6 m envelope, which is what makes it BRAID.
        for _ in range(rng.randint(2, 4)):
            if made >= VINE_TARGET:
                break
            width = rng.uniform(0.16, 0.42)
            pts, radii = vine_run(rng, h, cx, cz, hs,
                                  x0 + rng.uniform(-1.8, 1.8),
                                  y0 + rng.uniform(-1.8, 1.8),
                                  rng.uniform(4.0, 11.0), width)
            mb = MB()
            mb.tube(0, pts, radii, 6, ridge=rng.uniform(0.05, 0.14),
                    seed=rng.random() * 99.0)
            # One vine in six glows. The reference's live emerald roots are
            # 0.8-1.2% of area; the rest of the web is a pale unlit tube, and
            # making all of it a light source is what read as a neon scribble.
            live = rng.random() < 0.16
            if live:
                for k in range(2, len(pts) - 1, 4):
                    q = pts[k]
                    mb.orb(0, (q[0], q[1], q[2] + radii[k] * 0.8),
                           radii[k] * 0.8, 6, 4)
            make_object("vine_%d" % made, mb, [mats[2] if live else mats[1]])
            made += 1
    print("PY: %d vines from %d root-mat cells" % (made, len(seeds)))
    return low, high_ground


def bake(low, res_x, res_y):
    sc = bpy.context.scene
    # A NORMAL bake is geometric, not a light integration, so samples buy
    # nothing here. A DIFFUSE colour-only bake is the same. 4 is not a corner
    # cut; more would be identical output for minutes more CPU.
    cycles_cpu(sc, 4)
    sc.render.bake.use_selected_to_active = True
    sc.render.bake.use_cage = False
    sc.render.bake.cage_extrusion = CAGE_M
    sc.render.bake.max_ray_distance = CAGE_M * 2.0

    mat = bpy.data.materials.new("bake")
    mat.use_nodes = True
    low.data.materials.clear()
    low.data.materials.append(mat)
    node = mat.node_tree.nodes.new("ShaderNodeTexImage")
    mat.node_tree.nodes.active = node

    sources = [o for o in sc.objects if o.type == 'MESH' and o is not low]
    print("PY: baking %d source objects onto the map at %dx%d"
          % (len(sources), res_x, res_y))

    def _bake(kind, path, setup=None):
        img = bpy.data.images.new("bake_" + kind, res_x, res_y, alpha=False,
                                  float_buffer=False)
        node.image = img
        mat.node_tree.nodes.active = node
        bpy.ops.object.select_all(action='DESELECT')
        for o in sources:
            o.select_set(True)
        low.select_set(True)
        bpy.context.view_layer.objects.active = low
        if setup:
            setup()
        bpy.ops.object.bake(type=kind)
        img.filepath_raw = path
        img.file_format = 'PNG'
        img.save()
        print("PY: wrote %s" % path)

    _bake('NORMAL', OUT_N)

    def _colour_only():
        sc.render.bake.use_pass_direct = False
        sc.render.bake.use_pass_indirect = False
        sc.render.bake.use_pass_color = True

    _bake('DIFFUSE', OUT_C, _colour_only)


def main():
    rng = random.Random(SEED)
    meta, cx, cz, h, mat = load_map()
    hs = meta["height_scale_m"]
    void = meta.get("void_below", 0.0)
    res_y = int(round(RES_X * (cz - 1.0) / (cx - 1.0)))
    bpy.ops.wm.read_factory_settings(use_empty=True)
    low, _ = build(rng, cx, cz, h, mat, hs, void)
    os.makedirs(os.path.dirname(BLEND), exist_ok=True)
    bake(low, RES_X, res_y)
    bpy.ops.wm.save_as_mainfile(filepath=BLEND)
    print("PY: wrote %s" % BLEND)


main()
