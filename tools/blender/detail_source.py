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
GROUND_SUBDIV = int(argv[3]) if len(argv) > 3 else 3
SEED = 20260916

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DATA = os.path.join(ROOT, "build", "biodome")
BLEND = os.path.join(ROOT, "art", "detail_source.blend")
OUT_N = os.path.join(ROOT, "textures", "ground_detail_n.png")
OUT_C = os.path.join(ROOT, "textures", "ground_detail_c.png")

# Sampled from docs/reference/01-vtt-cavern-map.jpg. NOTHING here is light grey:
# that value belongs to the machines, and a landscape that shares it hides them.
#
# MEASURED, AND CORRECTED. The previous pass drifted the ground toward moss and
# olive to get "more colour variation", and overshot into a different hue
# family: the baked colour map came out at median hue 147 degrees with 40% of
# it in the greens, and the frame it produced measured 156 degrees against
# reference 01's 188. Green was 57% of the render and 4% of the reference.
#
# The reference's ground variety is not green. It is 77% teal, 17% BLUE and 4%
# green — the drift runs toward deep blue-teal, not toward moss. Moss belongs
# to the clumps, which are small enough not to move the median.
GROUND_MID = "143c3c"      # hue 180. The beige drift is strong enough that
                           # a weaker teal under it left the floor grey: the
                           # render fell to saturation 0.34 against 0.46.
VINE_BODY = "31534f"       # the pale structural tube: the dominant web
LIVE_BODY = "2e6640"       # the glowing emerald roots: a small MINORITY
GLOW = "5cc79a"
# The DRESSING, and this is where the colour variety lives.
#
# Reference 01 measures as almost monochrome — 69-80% of its saturated pixels
# in hue 170-210, and every warm hue together 0.38% of the image. References 02
# and 03 are far more varied. Both are wanted, and the resolution is that the
# GROUND STRUCTURE stays teal while the things GROWING on it carry the hue.
# Spread these across the flats themselves and the map stops reading as one
# place; keep them as clumps and they read as life.
MOSS_CLUMP = "3c5c42"      # mossy green, ref 02's floor — duller
CORAL_PINK = "98496a"
CORAL_RUST = "8e5228"      # the warm rust ref 02 has and ref 01 does not
BRAIN_VIOLET = "5e3e88"
PORE = "ff9a3c"            # the amber ocelli all over ref 03
# THE GROUND'S OWN TWO DRIFTS, and both stay inside the reference's hue family.
# The old pair were 3e5a3a (hue 105) and 4a7a44 (hue 114) at heavy weight,
# which is what turned the map green.
GROUND_DEEP = "153039"     # hue 197: the blue-teal that is 17% of reference 01
# THE BEIGE. Measured off reference 01 at rgb(92, 79, 69) — see build_flora's
# PALETTE for why the earlier "no warm hues" reading missed it entirely.
GROUND_SAND = "5c5348"     # near-neutral, warm: see ground_paint on the route
GROUND_WEED = "23423a"     # hue 163: as far toward green as the ground goes
GROUND_RUST = "5c4635"     # warm grey, on high dry ground

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


def _painted_mat(name, hexs, rough=0.85, emit=None, emit_w=0.0):
    """A flat base colour MULTIPLIED by the mesh's "paint" attribute.

    The vines carry a per-vertex gradient now (see vine_paint), and a plain
    Principled BSDF ignores it — the attribute would be written, baked over,
    and nothing in the output would change. This is the two nodes that make it
    count: the slot still decides WHAT the thing is made of, the attribute
    decides how dark and how warm this particular one is.
    """
    m = _mat(name, hexs, rough, emit, emit_w)
    nt = m.node_tree
    b = nt.nodes["Principled BSDF"]
    attr = nt.nodes.new("ShaderNodeVertexColor")
    attr.layer_name = "paint"
    mul = nt.nodes.new("ShaderNodeMix")
    mul.data_type = 'RGBA'
    mul.blend_type = 'MULTIPLY'
    mul.inputs["Factor"].default_value = 1.0
    mul.inputs[6].default_value = hexcol(hexs)
    nt.links.new(attr.outputs["Color"], mul.inputs[7])
    nt.links.new(mul.outputs[2], b.inputs["Base Color"])
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


def _grain(x, y, hs):
    """Fine surface relief for the high-detail ground, in metres.

    THREE BANDS, and the smallest is the point. The low-poly map is one vertex
    per metre, so a bake off an undisplaced copy of it can only ever carry the
    vines — the ground between them comes out perfectly smooth, which is most
    of why the floor reads as a painted plane with things lying on it. These
    are a 4 m swell, a 90 cm lumpiness and a 20 cm grain, and together they are
    what a normal map is for: relief far too small to be geometry in the game
    and far too important to leave out.
    """
    return ((_vnoise(x * 0.25 + 5.0, y * 0.25 + 9.0) - 0.5) * 0.115
            + (_vnoise(x * 1.1 + 31.0, y * 1.1 + 17.0) - 0.5) * 0.055
            + (_vnoise(x * 5.0 + 71.0, y * 5.0 + 3.0) - 0.5) * 0.022)


def terrain(cx, cz, h, hs, void, name, mats, paint=None, subdiv=1):
    """The map as a mesh, with the heightfield's own UV.

    `subdiv` > 1 builds it at that many vertices per metre and adds _grain().
    The BAKE TARGET stays at subdiv 1 and undisplaced — it is the low-poly the
    cage fires at, and displacing it would bake the grain into itself and
    cancel it out.
    """
    me = bpy.data.meshes.new(name + "_mesh")
    nx, nz = (cx - 1) * subdiv + 1, (cz - 1) * subdiv + 1
    verts = []
    for zi in range(nz):
        for xi in range(nx):
            x, y = xi / subdiv, zi / subdiv
            z = height_at(h, cx, cz, x, y) * hs
            if subdiv > 1:
                z += _grain(x, y, hs)
            verts.append((x, y, z))
    faces = []
    for zi in range(nz - 1):
        for xi in range(nx - 1):
            q = (zi * nx + xi, zi * nx + xi + 1,
                 (zi + 1) * nx + xi + 1, (zi + 1) * nx + xi)
            if void > 0.0 and any(
                    h[min(cz - 1, int(round(verts[i][1]))) * cx
                      + min(cx - 1, int(round(verts[i][0])))] < void for i in q):
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
        # Metres, not vertex index: the high mesh is subdivided and the low one
        # is not, and they have to land on the same UV or the bake is offset.
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


def vine_paint(rng, pts, radii, live, hs):
    """One colour per point along a vine, as a multiplier on its material.

    THE VINES WERE ONE FLAT TEAL. A material slot is one colour over every
    triangle assigned to it, so four thousand vines all came out of the bake
    identical — and a web whose every strand is the same value reads as a
    diagram of a web. Reference 03's are not: each tube darkens into the
    ground at its feet, pales along its back where the light sits, and no two
    of them are quite the same colour.

    Three things vary here, and they are three different arguments:
      - PER VINE, a hue and value jitter, so neighbours differ.
      - ALONG the vine, a dark root and a paler tip.
      - PER POINT, the swell: where the tube is fattest it catches more light,
        which is the thing that makes a swelling read as a swelling.
    """
    warm = rng.uniform(-0.05, 0.10)          # toward beige, or away from it
    lift = rng.uniform(0.74, 1.24)
    rmax = max(radii) or 1.0
    out = []
    n = max(1, len(pts) - 1)
    for i, p in enumerate(pts):
        t = i / n
        # Dark at the root, pale toward the tip, and the ends taper back down
        # so a vine does not end on a highlight.
        run = 0.70 + 0.55 * t - 0.25 * max(0.0, t - 0.82) / 0.18
        fat = 0.88 + 0.34 * (radii[i] / rmax)
        v = lift * run * fat
        # Height: the mats down in the channels are wetter and darker than the
        # ones over a lobe top, which is a real gradient across the whole map
        # rather than a per-vine one.
        v *= 0.86 + 0.28 * _fit(p[2] / max(1.0, hs), 0.30, 0.85)
        g = 1.0 + warm * 0.4
        r = 1.0 + warm * 1.8
        b = 1.0 - warm * 1.2
        if live:
            # The glowing minority pales toward its own emission instead of
            # toward beige, or the emissive slot fights the paint.
            r, g, b = 0.86, 1.06, 1.0
        out.append((v * r, v * g, v * b, 1.0))
    return out


def grow_vine(mb, slot, rng, h, cx, cz, hs, x0, y0, length, width, depth=0):
    """A vine AND what grows off it. Returns the trunk's points and radii.

    This is the difference between the first pass and reference 03. There, a
    vine is not a tube — it is a trunk that BRANCHES, with nodules swelling
    along it and glowing pores set into the swellings. A single swept tube can
    never look like that however it is tuned, because the structure is missing
    rather than the detail.
    """
    pts, radii, ang = vine_run(rng, h, cx, cz, hs, x0, y0, length, width)
    cols = vine_paint(rng, pts, radii, slot == 2, hs)
    mb.tube(slot, pts, radii, 6 if depth else 7, ring_cols=cols,
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
               col=cols[k], lumps=0.25, seed=rng.random() * 40.0)

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


def clump(mb, slot, rng, at, r, n, squash=1.0, col=None):
    """A cluster of lobes — coral, fungus, brain growth. The dressing."""
    for _ in range(n):
        a = rng.uniform(0, math.tau)
        d = r * math.sqrt(rng.random())
        mb.orb(slot, (at[0] + math.cos(a) * d, at[1] + math.sin(a) * d,
                   at[2] + rng.uniform(0.0, r * 0.7)),
               r * rng.uniform(0.28, 0.6), 7, 5, col=col,
               squash=squash, lumps=0.3, seed=rng.random() * 70.0)


def build(rng, cx, cz, h, mat, hs, void):
    # Every non-emissive slot is PAINTED — its flat colour multiplied by the
    # per-vertex attribute. The emissive two are not: a light source with a
    # value gradient baked into it reads as a dirty bulb.
    mats = [_mat("ground", GROUND_MID, 0.92),
            _painted_mat("vine", VINE_BODY, 0.80),
            _mat("live", LIVE_BODY, 0.70, GLOW, 2.5),
            _painted_mat("moss", MOSS_CLUMP, 0.95),
            _painted_mat("coral_p", CORAL_PINK, 0.78),
            _painted_mat("coral_r", CORAL_RUST, 0.80),
            _painted_mat("brain", BRAIN_VIOLET, 0.72),
            _mat("pore", "3a1c07", 0.40, PORE, 4.0),
            _painted_mat("bone", "6b6052", 0.86)]
    VINE, LIVE, MOSS, CPINK, CRUST, BRAIN, POREM, BONE = 1, 2, 3, 4, 5, 6, 7, 8

    # THE FLOOR'S OWN COLOUR, drifting between the two references.
    #
    # Three bands of low-frequency value noise decide how mossy, how olive and
    # how warm each patch of ground is. Teal stays the base — reference 01 is
    # 69-80% hue 170-210 and the map has to read as one place — but the drift
    # takes it toward reference 02's mossy green over tens of metres, with rust
    # kept rare and only on high dry ground, which is where 02 puts it.
    def ground_paint(x, y, z):
        # FIVE BANDS AT FOUR SCALES, which is what "more gradient" means here.
        #
        # Two low-frequency drifts decide the region's character over tens of
        # metres; a mid band breaks those into patches at five or six metres;
        # a fine band mottles at under a metre. A single band at one scale
        # reads as a stain however it is tuned, because real ground varies at
        # every scale at once — reference 03 is the whole argument for this.
        sand = _vnoise(x * 0.024 + 61.0, y * 0.024 + 29.0)     # ~42 m
        deep = _vnoise(x * 0.031 + 19.3, y * 0.031 + 2.4)      # ~32 m
        weed = _vnoise(x * 0.055 + 3.1, y * 0.055 + 7.7)       # ~18 m
        patch = _vnoise(x * 0.19 + 44.0, y * 0.19 + 88.0)      # ~5 m
        mottle = _vnoise(x * 1.35 + 12.0, y * 1.35 + 55.0)     # ~75 cm
        base = list(hexcol(GROUND_MID))
        for i in range(3):
            # BEIGE FIRST, and it is the largest single drift on the map now.
            # Reference 01's floor is not one teal: the dry ground between the
            # root mats reads warm grey, and it is the only warm thing in the
            # picture, which is exactly why it carries.
            # AND IT GOES VIA GREY, NOT VIA GREEN. The straight line from this
            # teal to a saturated beige passes through hue 128 in the middle,
            # so a strong drift toward #4e463b made a THIRD of the map green —
            # exactly what it was meant to remove. A near-neutral warm grey
            # loses the chroma first and picks up the warmth second, and the
            # green band drops from 35% to 8% at a stronger weight than before.
            base[i] += (hexcol(GROUND_SAND)[i] - base[i]) * _fit(sand, 0.30, 0.78) * 0.90
            base[i] += (hexcol(GROUND_DEEP)[i] - base[i]) * _fit(deep, 0.48, 0.88) * 0.52
            # The green is now a MINORITY band and a narrow one: it appears
            # where two drifts happen to agree rather than across a third of
            # the map, which is what it was doing.
            base[i] += (hexcol(GROUND_WEED)[i] - base[i]) * _fit(weed, 0.62, 0.92) * 0.14
        # Dry high ground goes warmer still, and the patch band decides where
        # within that, so the warm areas have an edge instead of a gradient.
        dry = _fit(z / max(1.0, hs), 0.52, 0.90)
        for i in range(3):
            base[i] += (hexcol(GROUND_RUST)[i] - base[i]) \
                * _fit(patch, 0.58, 0.95) * dry * 0.48
        # And the mottle, as a value shift only — a hue that changes at 75 cm
        # reads as noise, a value that changes at 75 cm reads as texture.
        v = 1.0 + (mottle - 0.5) * 0.30
        return (base[0] * v, base[1] * v, base[2] * v, 1.0)

    low = terrain(cx, cz, h, hs, void, "bake_target", [mats[0]])
    # THREE VERTICES PER METRE on the high copy. The low-poly is one per metre
    # and the bake fires at it from a cage, so every scrap of relief finer than
    # a metre has to exist on this mesh or it exists nowhere. At subdiv 1 the
    # ground between the vines baked perfectly flat, which is most of why the
    # floor read as a painted plane with things lying on it.
    high_ground = terrain(cx, cz, h, hs, void, "high_ground",
                          [_vertex_colour_mat("ground_painted")], ground_paint,
                          subdiv=GROUND_SUBDIV)

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
                           radii[k] * 0.34, 6, 4)  # emissive: left unpainted
            made += 1

    # A SECOND, FINER TIER. The reference's web is layered: heavy trunks with a
    # mat of much thinner runners threaded over and under them. One tier at one
    # thickness reads as a diagram of a web rather than a web, however dense it
    # gets — what makes it look grown is two scales crossing each other.
    #
    # These are a third the radius and run shorter, so they add length and
    # crossings without adding bulk, and they are seeded from the same cells so
    # they land on top of the trunks rather than in the open.
    fine = 0
    for i in seeds:
        if fine >= VINE_TARGET // 2:
            break
        if rng.random() > 0.45:
            continue
        x0, y0 = i % cx, i // cx
        pts, radii, _ = vine_run(rng, h, cx, cz, hs,
                                 x0 + rng.uniform(-2.4, 2.4),
                                 y0 + rng.uniform(-2.4, 2.4),
                                 rng.uniform(2.5, 6.0),
                                 rng.uniform(0.06, 0.16))
        mb.tube(VINE, pts, radii, 5,
                ring_cols=vine_paint(rng, pts, radii, False, hs),
                ridge=rng.uniform(0.10, 0.22), seed=rng.random() * 99.0)
        fine += 1
    print("PY: %d fine runners over the trunks" % fine)

    # A THIRD TIER, AND IT GOES UNDERNEATH.
    #
    # The other two lie on top of each other: trunks, then runners threaded
    # over them. That reads as a web draped on bare ground, because between
    # the trunks there IS bare ground. In the reference there is no bare
    # ground inside a patch — the trunks sit on a mat of much finer filament
    # that fills every gap, and the trunks read as heavy precisely because
    # something finer is underneath them for scale.
    #
    # vine_run lifts a vine by 0.04 + 0.12 * width, so at a third of the fine
    # tier's radius these land about 5 cm off the ground with the trunks
    # riding 30-40 cm above them. Nothing here has to be sunk deliberately;
    # the tier is under the others because it is thinner than them.
    #
    # Seeded wider than the trunks (+/- 4 m against +/- 1.8) so the mat spreads
    # into the gaps instead of bundling along the same lines.
    mat_runs = 0
    want_mat = int(VINE_TARGET * 1.5)
    for i in seeds:
        if mat_runs >= want_mat:
            break
        for _ in range(rng.randint(1, 3)):
            if mat_runs >= want_mat:
                break
            x0, y0 = i % cx, i // cx
            pts, radii, _ = vine_run(rng, h, cx, cz, hs,
                                     x0 + rng.uniform(-4.0, 4.0),
                                     y0 + rng.uniform(-4.0, 4.0),
                                     rng.uniform(1.4, 3.6),
                                     rng.uniform(0.035, 0.09))
            # Four sides, not five. At this radius the tube is under a
            # texel across in the bake and the extra ring buys nothing but
            # triangles — and there are four thousand of these.
            mb.tube(VINE, pts, radii, 4,
                    ring_cols=vine_paint(rng, pts, radii, False, hs),
                    ridge=rng.uniform(0.05, 0.14), seed=rng.random() * 99.0)
            mat_runs += 1
    print("PY: %d filaments in the mat under them" % mat_runs)

    # THE DRESSING: where the colour variety comes from.
    #
    # Scattered as CLUMPS on open ground rather than spread across the flats.
    # Reference 01's ground is nearly monochrome teal and references 02 and 03
    # are not; the way to have both is for the ground to stay teal and the
    # things growing on it to carry the hue. Spread thin, this reads as mud.
    open_cells = [i for i in range(cx * cz)
                  if mat[i] != VINE_MAT and h[i] > void + 0.06]
    rng.shuffle(open_cells)
    # More kinds, and more of them, from reference 03 — which is dense with
    # distinct growths rather than one repeated blob: mossy cushions, coral
    # fans, warm rust nodules, violet brain masses, pale pods and teal buttons.
    # BEIGE IS THE BIGGEST SHARE NOW AND MOSS IS A MINORITY. Reference 01 has
    # exactly two vivid green patches in the whole picture and they are small;
    # what it has a lot of is warm grey rubble. Moss at 0.30 made green the
    # most saturated thing on screen, which is the opposite of that.
    dressing = [(BONE, 0.8, 5, 0.45, 0.30),    # beige rubble and pods
                (CPINK, 0.6, 7, 0.85, 0.13),   # coral fans
                (CRUST, 0.55, 5, 0.70, 0.14),  # the warm rust ref 01 lacks
                (MOSS, 0.9, 7, 0.55, 0.11),    # mossy cushions, ref 02's floor
                (BRAIN, 1.2, 10, 0.45, 0.07),  # violet brain mass
                (LIVE, 0.45, 5, 0.9, 0.09),    # teal glowing buttons
                (POREM, 0.22, 3, 1.0, 0.16)]   # amber ocelli, everywhere in 03
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
        # One value per clump, so a field of them is not a field of clones.
        v = rng.uniform(0.66, 1.30)
        w = rng.uniform(-0.05, 0.09)
        clump(mb, slot, rng, (x0, y0, z), r * rng.uniform(0.7, 1.5), n, squash,
              col=(v * (1.0 + w * 1.8), v * (1.0 + w * 0.4), v * (1.0 - w * 1.2), 1.0))
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
