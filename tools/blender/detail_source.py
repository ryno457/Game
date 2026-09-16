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
CLUMP_TARGET = int(argv[2]) if len(argv) > 2 else 260
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
# The DRESSING, and this is where the colour variety lives.
#
# Reference 01 measures as almost monochrome — 69-80% of its saturated pixels
# in hue 170-210, and every warm hue together 0.38% of the image. References 02
# and 03 are far more varied. Both are wanted, and the resolution is that the
# GROUND STRUCTURE stays teal while the things GROWING on it carry the hue.
# Spread these across the flats themselves and the map stops reading as one
# place; keep them as clumps and they read as life.
MOSS_CLUMP = "4a7a44"      # mossy green, ref 02's floor
CORAL_PINK = "b05a7a"
CORAL_RUST = "a8622e"      # the warm rust ref 02 has and ref 01 does not
BRAIN_VIOLET = "6f4a9c"
PORE = "ff9a3c"            # the amber ocelli all over ref 03
GROUND_OLIVE = "3e5a3a"    # the drift toward ref 02
GROUND_RUST = "6b4a30"     # rare, and only on high dry ground

VINE_MAT = 4               # GroundMaterials.VINE
CAGE_M = 1.4               # tallest vine ~0.9 m, plus margin


def _vnoise(x, y):
    """Smooth value noise. Blender has no cheap CPU-side noise worth importing
    for three octaves, and a hash is four lines."""
    xi, yi = math.floor(x), math.floor(y)
    fx, fy = x - xi, y - yi
    fx = fx * fx * (3.0 - 2.0 * fx)
    fy = fy * fy * (3.0 - 2.0 * fy)

    def hsh(a, b):
        n = math.sin(a * 127.1 + b * 311.7) * 43758.5453
        return n - math.floor(n)

    return ((hsh(xi, yi) * (1 - fx) + hsh(xi + 1, yi) * fx) * (1 - fy)
            + (hsh(xi, yi + 1) * (1 - fx) + hsh(xi + 1, yi + 1) * fx) * fy)


def _fit(v, lo, hi):
    return min(1.0, max(0.0, (v - lo) / max(1e-6, hi - lo)))


def _vertex_colour_mat(name, rough=0.92):
    """A material whose base colour comes from the mesh's own vertex colours.

    This is how the floor gets colour VARIATION rather than one flat teal.
    Reference 02's ground is mossy green, reference 01's is teal, and the floor
    should drift between them across tens of metres the way both do — that is a
    property of the surface, not of things scattered on it, so it has to live in
    the mesh. Scattering more coloured clumps cannot produce it: at 19 px/m a
    clump is a handful of pixels and a thousand of them still read as confetti
    over a monotone field.
    """
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Roughness"].default_value = rough
    attr = m.node_tree.nodes.new("ShaderNodeVertexColor")
    attr.layer_name = "ground"
    m.node_tree.links.new(attr.outputs["Color"], b.inputs["Base Color"])
    return m


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


def terrain(cx, cz, h, hs, void, name, mats, paint=None):
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
    if paint is not None:
        col = me.color_attributes.new("ground", 'FLOAT_COLOR', 'POINT')
        for vi, mv in enumerate(me.vertices):
            v = mv.co
            col.data[vi].color = paint(v.x, v.y, v.z)
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


def vine_run(rng, h, cx, cz, hs, x0, y0, length, width, ang=None):
    """One vine, following the ground, wandering and swelling along its length.

    The swell is the point. A swept tube of constant radius reads as a pipe; the
    reference's vines pinch and bulge several times along their length, which is
    what makes them read as grown. Both ends taper so a vine emerges from the
    ground rather than stopping dead.
    """
    pts, radii = [], []
    x, y = x0, y0
    if ang is None:
        ang = rng.uniform(0, math.tau)
    steps = max(5, int(length / 0.8))
    for i in range(steps):
        t = i / float(steps - 1)
        ang += rng.uniform(-0.40, 0.40)
        step = length / steps
        x += math.cos(ang) * step
        y += math.sin(ang) * step
        x = min(max(x, 1.0), cx - 2.0)
        y = min(max(y, 1.0), cz - 2.0)
        z = height_at(h, cx, cz, x, y) * hs
        pts.append((x, y, z + 0.04 + 0.12 * width))
        swell = 0.55 + 0.45 * math.sin(t * math.pi * rng.uniform(1.6, 3.8))
        ends = min(1.0, 3.2 * min(t, 1.0 - t) + 0.20)
        radii.append(width * swell * ends)
    return pts, radii, ang


def grow_vine(mb, slot, rng, h, cx, cz, hs, x0, y0, length, width, depth=0):
    """A vine AND what grows off it. Returns the trunk's points and radii.

    This is the difference between the first pass and reference 03. There, a
    vine is not a tube — it is a trunk that BRANCHES, with nodules swelling
    along it and glowing pores set into the swellings. A single swept tube can
    never look like that however it is tuned, because the structure is missing
    rather than the detail.
    """
    pts, radii, ang = vine_run(rng, h, cx, cz, hs, x0, y0, length, width)
    mb.tube(slot, pts, radii, 6 if depth else 7,
            ridge=rng.uniform(0.08, 0.20), seed=rng.random() * 99.0)

    # NODULES. Swellings along the trunk, biggest where the trunk is thickest.
    # In the reference the light does not sit on the vine, it sits in beads
    # strung along it — so the nodules are also where the pores go.
    for k in range(1, len(pts) - 1, rng.randint(2, 4)):
        if rng.random() > 0.55:
            continue
        q = pts[k]
        r = radii[k] * rng.uniform(1.15, 1.75)
        mb.orb(slot, (q[0], q[1], q[2] + radii[k] * 0.45), r, 7, 5,
               lumps=0.25, seed=rng.random() * 40.0)

    # BRANCHES, one level deep. Two levels doubles the triangle count for
    # structure the 19 px/m camera cannot resolve.
    if depth == 0:
        for _ in range(rng.randint(1, 3)):
            k = rng.randint(1, max(1, len(pts) - 2))
            q = pts[k]
            grow_vine(mb, slot, rng, h, cx, cz, hs, q[0], q[1],
                      length * rng.uniform(0.35, 0.6),
                      width * rng.uniform(0.45, 0.7), depth + 1)
    return pts, radii


def clump(mb, slot, rng, at, r, n, squash=1.0):
    """A cluster of lobes — coral, fungus, brain growth. The dressing."""
    for _ in range(n):
        a = rng.uniform(0, math.tau)
        d = r * math.sqrt(rng.random())
        mb.orb(slot, (at[0] + math.cos(a) * d, at[1] + math.sin(a) * d,
                   at[2] + rng.uniform(0.0, r * 0.7)),
               r * rng.uniform(0.28, 0.6), 7, 5,
               squash=squash, lumps=0.3, seed=rng.random() * 70.0)


def build(rng, cx, cz, h, mat, hs, void):
    mats = [_mat("ground", GROUND_MID, 0.92),
            _mat("vine", VINE_BODY, 0.80),
            _mat("live", LIVE_BODY, 0.70, GLOW, 2.5),
            _mat("moss", MOSS_CLUMP, 0.95),
            _mat("coral_p", CORAL_PINK, 0.78),
            _mat("coral_r", CORAL_RUST, 0.80),
            _mat("brain", BRAIN_VIOLET, 0.72),
            _mat("pore", "3a1c07", 0.40, PORE, 4.0)]
    VINE, LIVE, MOSS, CPINK, CRUST, BRAIN, POREM = 1, 2, 3, 4, 5, 6, 7

    # THE FLOOR'S OWN COLOUR, drifting between the two references.
    #
    # Three bands of low-frequency value noise decide how mossy, how olive and
    # how warm each patch of ground is. Teal stays the base — reference 01 is
    # 69-80% hue 170-210 and the map has to read as one place — but the drift
    # takes it toward reference 02's mossy green over tens of metres, with rust
    # kept rare and only on high dry ground, which is where 02 puts it.
    def ground_paint(x, y, z):
        moss = _vnoise(x * 0.022 + 3.1, y * 0.022 + 7.7)
        olive = _vnoise(x * 0.045 + 19.3, y * 0.045 + 2.4)
        warm = _vnoise(x * 0.017 + 41.0, y * 0.017 + 13.6)
        base = list(hexcol(GROUND_MID))
        for i in range(3):
            base[i] += (hexcol(MOSS_CLUMP)[i] - base[i]) * _fit(moss, 0.52, 0.86) * 0.55
            base[i] += (hexcol(GROUND_OLIVE)[i] - base[i]) * _fit(olive, 0.60, 0.90) * 0.38
        dry = _fit(z / max(1.0, hs), 0.62, 0.92)
        for i in range(3):
            base[i] += (hexcol(GROUND_RUST)[i] - base[i]) * _fit(warm, 0.76, 0.95) * dry * 0.55
        return (base[0], base[1], base[2], 1.0)

    low = terrain(cx, cz, h, hs, void, "bake_target", [mats[0]])
    high_ground = terrain(cx, cz, h, hs, void, "high_ground",
                          [_vertex_colour_mat("ground_painted")], ground_paint)

    # DENSITY, and it follows the map rather than a noise field. The classifier
    # already decided which cells are root mat; vines are seeded only there, so
    # the web lands exactly where the game's own materials, pathing and
    # gameplay already say it is. That also means the patches are the map's
    # patches — nothing here has to invent where the clear ground goes.
    seeds = [i for i in range(cx * cz) if mat[i] == VINE_MAT]
    rng.shuffle(seeds)

    # ONE MESH, not eighteen hundred. MB already carries a material index per
    # triangle, so every vine, branch, nodule, pore and clump can accumulate
    # into a single builder and come out as one object with eight slots.
    #
    # This is not tidiness. The first version made an object per vine, and at
    # full density Blender's depsgraph and Cycles' BVH build over ~1800 objects
    # took the bake past an hour and it was killed mid-pass. Same triangles, one
    # object: the per-object overhead simply goes away.
    mb = MB()
    made = 0
    for i in seeds:
        if made >= VINE_TARGET:
            break
        if rng.random() > 0.55:
            continue
        x0, y0 = i % cx, i // cx
        # A bundle, not a single vine: the reference's web is bundles of about
        # four crests inside a 3.6 m envelope, which is what makes it BRAID.
        for _ in range(rng.randint(2, 4)):
            if made >= VINE_TARGET:
                break
            # One vine in six glows. The reference's live emerald roots are
            # 0.8-1.2% of area; the rest of the web is a pale unlit tube, and
            # making all of it a light source read as a neon scribble.
            live = rng.random() < 0.16
            pts, radii = grow_vine(mb, LIVE if live else VINE, rng, h, cx, cz,
                                   hs, x0 + rng.uniform(-1.8, 1.8),
                                   y0 + rng.uniform(-1.8, 1.8),
                                   rng.uniform(5.0, 12.0),
                                   rng.uniform(0.20, 0.50))
            # PORES. In reference 03 these amber points are everywhere, and
            # they are the most characteristic small detail in it.
            if rng.random() < 0.45:
                for k in range(2, len(pts) - 1, 5):
                    if rng.random() > 0.5:
                        continue
                    q = pts[k]
                    mb.orb(POREM, (q[0], q[1], q[2] + radii[k] * 1.1),
                           radii[k] * 0.34, 6, 4)
            made += 1

    # THE DRESSING: where the colour variety comes from.
    #
    # Scattered as CLUMPS on open ground rather than spread across the flats.
    # Reference 01's ground is nearly monochrome teal and references 02 and 03
    # are not; the way to have both is for the ground to stay teal and the
    # things growing on it to carry the hue. Spread thin, this reads as mud.
    open_cells = [i for i in range(cx * cz)
                  if mat[i] != VINE_MAT and h[i] > void + 0.06]
    rng.shuffle(open_cells)
    dressing = [(MOSS, 0.9, 7, 0.55, 0.34),    # mossy green, ref 02's floor
                (CPINK, 0.6, 6, 0.8, 0.14),
                (CRUST, 0.55, 5, 0.7, 0.12),   # the warm rust ref 01 lacks
                (BRAIN, 1.1, 9, 0.5, 0.06)]
    dressed = 0
    for i in open_cells[:CLUMP_TARGET * 4]:
        if dressed >= CLUMP_TARGET:
            break
        slot, r, n, squash, share = dressing[
            min(range(len(dressing)),
                key=lambda k: abs(rng.random() - dressing[k][4]))]
        if rng.random() > share * 3.0:
            continue
        x0, y0 = i % cx, i // cx
        z = height_at(h, cx, cz, x0, y0) * hs
        clump(mb, slot, rng, (x0, y0, z), r * rng.uniform(0.7, 1.5), n, squash)
        dressed += 1

    make_object("detail", mb, mats)
    print("PY: %d vines and %d clumps in ONE mesh, %d tris"
          % (made, dressed, mb.tris))

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
