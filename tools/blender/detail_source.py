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
import json
import math
import os
import random
import struct
import sys

import bpy
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _bl import cycles_cpu, script_args          # noqa: E402
from build_flora import MB, hexcol, make_object  # noqa: E402

argv = script_args()
RES_X = int(argv[0]) if argv else 2048
VINE_TARGET = int(argv[1]) if len(argv) > 1 else 520
CLUMP_TARGET = int(argv[2]) if len(argv) > 2 else 260
GROUND_SUBDIV = int(argv[3]) if len(argv) > 3 else 3
## HALF. Every vine radius is multiplied by this. Length is left alone: a
## vine's visual weight at the overhead camera is its thickness, and halving
## the runs as well would have thinned the mat's coverage to a quarter for a
## change that was asked for as 'smaller', not 'sparser'.
VINE_SCALE = 0.5
## And the count goes UP to pay for it. Halving the radius halves the ground
## a vine covers per metre of its length, so at the old count the mat thinned
## out and the bare floor came through: measured, the baked map went from 45%
## near-grey to 49% and the rendered frame's saturation fell from 0.35 to
## 0.27. Smaller was the ask; sparser was not.
VINE_COUNT_SCALE = 1.75
## Metres of ground covered by one tile of the scale map. The generator lays
## 12 scales across a tile, so this over 12 is how big one scale is: at 5 m
## that is 42 cm. At 25 cm it aliased: the bake is 2048 over 150 m, so a texel
## is 7 cm and a 25 cm scale had three of them to be drawn with.
SCALE_M = 5.0
SEED = 20260916

## WHICH LAYOUT TO BUILD. Two, and they write to different files.
##
##   mat     the root-mat web: three tiers of one plant, seeded only on the
##           cells the material classifier already called VINE, which is 20%
##           of the map. What the game shipped before this.
##   vines   THREE SPECIES over the WHOLE landmass, each with its own seed,
##           colour and size class. A separate .blend and a separate pair of
##           textures, so the first layout is still there to go back to.
##
## One generator with a switch rather than a forked copy of it: everything
## except where the vines go and how big they are is identical, and a second
## seven-hundred-line script would be the same file until the day somebody
## fixed a bug in one of them.
PROFILE = argv[4] if len(argv) > 4 else "mat"
WHOLE_MAP = PROFILE == "vines"

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DATA = os.path.join(ROOT, "build", "biodome")
MODELS = os.path.join(ROOT, "models")
BLEND = os.path.join(ROOT, "art",
                     "detail_vines.blend" if WHOLE_MAP else "detail_source.blend")
OUT_N = os.path.join(ROOT, "textures",
                     "ground_vines_n.png" if WHOLE_MAP else "ground_detail_n.png")
OUT_C = os.path.join(ROOT, "textures",
                     "ground_vines_c.png" if WHOLE_MAP else "ground_detail_c.png")
OUT_D = os.path.join(ROOT, "textures",
                     "ground_vines_d.png" if WHOLE_MAP else "ground_detail_d.png")

## THE THREE SPECIES, for PROFILE = "vines".
##
## name, seed, colour, radius range (m), length range (m), share of the seeded
## cells it takes, and how many splines one seeded cell produces.
##
## Their seeds are independent on purpose: three fields that happen to share a
## random stream are not three species, they are one species drawn three times,
## and the giveaway is that they all thin out in the same places.
##
## SIZE IS BOUNDED BY THE MACHINES. The largest vine has to stay smaller than
## the smallest machine on the map or the mat swallows the things the player is
## meant to be looking at — and "smaller" is checked against the models
## themselves in _check_species_scale(), not against a number typed here that
## would go stale the first time a chassis changed.
## SIZED AGAINST THE BAKE, not against a plant. The first pass ran 22-48 mm,
## 55-95 mm and 105-160 mm, which is a sensible set of vines and the wrong set
## for this pipeline: the bake is 2048 texels over 150 m, so a texel is 7 cm
## and the small species was a THIRD of one. It contributed noise, the middle
## species drew about one texel wide, and the frame came back at saturation
## 0.30 with the mat reading as scratches. Everything here is roughly doubled.
SPECIES = [
    # SMALL: the ground cover. Dense, fine, and the only one that reaches
    # everywhere — the other two grow through it.
    ("small", 71, "2f6b5f", (0.045, 0.085), (0.9, 2.4), 0.55, 3),
    # MIDDLE: the connective web, and the one that reads as a web at all.
    ("middle", 20261, "2b5f66", (0.100, 0.170), (2.5, 5.5), 0.28, 2),
    # LARGE: sparse trunks. Greener and duller than the other two, so a big one
    # reads as an older thing than the mat it lies on — but still a PLANT. At
    # 5a6150 it measured saturation 0.18, and 1256 of the thickest tubes on the
    # map at almost no chroma is what took the frame to 0.32 against a 0.34
    # floor. A vine that desaturated is a stick.
    ("large", 918273, "4a6356", (0.190, 0.270), (5.0, 11.0), 0.10, 1),
]

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
VINE_BODY = "2a6058"       # the pale structural tube: the dominant web
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
VINE_MAT_SLOT = 1          # the MB material index the vine body uses
CAGE_M = 1.4               # tallest vine ~0.9 m, plus margin
## What one unit of the DEPTH map means, in metres. Not the cage: the cage is
## how far a ray may travel to find geometry, and the relief it finds is a
## fraction of that. Normalised over CAGE_M the whole map landed in the bottom
## 15% of the 8 bits and came out as speckle. This is the tallest species plus
## a margin, and the fraction that clips is reported at bake time.
DEPTH_RANGE_M = 0.90


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


def _vertex_colour_mat(name, rough=0.92, scale_tile=None):
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
    if scale_tile is not None:
        # THE SAME SKIN THE VINES WEAR. The ground's unwrap is the whole map in
        # 0..1, so the tile count is the map's size over the scale's size —
        # which is what makes one scale a fixed number of centimetres however
        # big the map gets.
        _scale_nodes(m.node_tree, b.inputs["Normal"], scale_tile, 0.55)
    return m


def _painted_mat(name, hexs, rough=0.85, emit=None, emit_w=0.0):
    """A flat base colour MULTIPLIED by the mesh's "paint" attribute.

    The clumps carry a per-clump colour now, and a plain
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


SCALE_N = os.path.join(ROOT, "textures", "scale_detail_n.png")


def _scale_nodes(nt, base_socket, tile=(6.0, 1.0), strength=1.0):
    """Wire the seamless scale map into a material's Normal input.

    Uses the curve's OWN generated UV — Blender lays one out along a bevelled
    spline, U around the tube and V from root to tip — so the scales run along
    the vine the way scales on a thing actually do. A triplanar or object-space
    projection would put them in world axes and the vine would look painted.
    """
    if not os.path.exists(SCALE_N):
        return None
    img = bpy.data.images.load(SCALE_N, check_existing=True)
    img.colorspace_settings.name = 'Non-Color'
    uv = nt.nodes.new("ShaderNodeUVMap")
    mapn = nt.nodes.new("ShaderNodeMapping")
    mapn.inputs["Scale"].default_value = (tile[0], tile[1], 1.0)
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = img
    tex.extension = 'REPEAT'
    nm = nt.nodes.new("ShaderNodeNormalMap")
    nm.inputs["Strength"].default_value = strength
    nt.links.new(uv.outputs["UV"], mapn.inputs["Vector"])
    nt.links.new(mapn.outputs["Vector"], tex.inputs["Vector"])
    nt.links.new(tex.outputs["Color"], nm.inputs["Color"])
    nt.links.new(nm.outputs["Normal"], base_socket)
    return nm


def _vine_curve_mat(name, hexs, rough=0.80, emit=None, emit_w=0.0,
                    tile=(8.0, 1.0)):
    """The vine material, with everything the vertex paint used to carry.

    A curve cannot hold a colour attribute, so the three variations that used
    to live in COLOR_0 come out of coordinates instead — and they are better
    for it, because a curve's UV knows where the ROOT and the TIP are and a
    vertex colour only knew where the vertex was:

      ALONG THE VINE   a ramp on V: dark at the root, paler toward the tip.
      PER VINE         a noise on object coordinates at about two metres, so
                       each vine sits at its own value and its neighbour does
                       not. Spatial rather than per-object, which is the whole
                       reason four thousand vines can share three datablocks.
      THE SKIN         the seamless scale map, running along the tube.
    """
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    b = nt.nodes["Principled BSDF"]
    b.inputs["Roughness"].default_value = rough
    if emit is not None and "Emission Color" in b.inputs:
        b.inputs["Emission Color"].default_value = hexcol(emit)
        b.inputs["Emission Strength"].default_value = emit_w

    uv = nt.nodes.new("ShaderNodeUVMap")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(uv.outputs["UV"], sep.inputs["Vector"])
    run = nt.nodes.new("ShaderNodeValToRGB")
    run.color_ramp.elements[0].position = 0.0
    run.color_ramp.elements[0].color = (0.62, 0.62, 0.62, 1.0)
    run.color_ramp.elements[1].position = 1.0
    run.color_ramp.elements[1].color = (1.28, 1.28, 1.28, 1.0)
    nt.links.new(sep.outputs["Y"], run.inputs["Fac"])

    coord = nt.nodes.new("ShaderNodeTexCoord")
    noise = nt.nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 0.55
    noise.inputs["Detail"].default_value = 1.0
    nt.links.new(coord.outputs["Object"], noise.inputs["Vector"])
    jit = nt.nodes.new("ShaderNodeValToRGB")
    jit.color_ramp.elements[0].color = (0.70, 0.74, 0.82, 1.0)
    jit.color_ramp.elements[1].color = (1.30, 1.22, 1.06, 1.0)
    nt.links.new(noise.outputs["Fac"], jit.inputs["Fac"])

    mul1 = nt.nodes.new("ShaderNodeMix")
    mul1.data_type = 'RGBA'
    mul1.blend_type = 'MULTIPLY'
    mul1.inputs["Factor"].default_value = 1.0
    mul1.inputs[6].default_value = hexcol(hexs)
    nt.links.new(run.outputs["Color"], mul1.inputs[7])

    mul2 = nt.nodes.new("ShaderNodeMix")
    mul2.data_type = 'RGBA'
    mul2.blend_type = 'MULTIPLY'
    mul2.inputs["Factor"].default_value = 1.0
    nt.links.new(mul1.outputs[2], mul2.inputs[6])
    nt.links.new(jit.outputs["Color"], mul2.inputs[7])
    nt.links.new(mul2.outputs[2], b.inputs["Base Color"])

    _scale_nodes(nt, b.inputs["Normal"], tile, 0.85)
    return m


def smallest_machine_m():
    """The smallest machine on the map, in metres, read from the models.

    The large vine species has to stay under this — a mat with a strand
    thicker than the drone in it stops being ground the machines stand on and
    starts being terrain they are lost in. Measured off the exported glTF
    rather than typed here, because a number typed here goes stale the first
    time a chassis changes and nothing notices.
    """
    best = 1.0e9
    for name in ("drone", "guard", "bulwark", "turret"):
        path = os.path.join(MODELS, name + ".glb")
        if not os.path.exists(path):
            continue
        with open(path, "rb") as f:
            struct.unpack("<4sII", f.read(12))
            n, _kind = struct.unpack("<II", f.read(8))
            doc = json.loads(f.read(n).decode("utf-8"))
        lo = [9e9] * 3
        hi = [-9e9] * 3
        for m in doc["meshes"]:
            for prim in m["primitives"]:
                a = doc["accessors"][prim["attributes"]["POSITION"]]
                for k in range(3):
                    lo[k] = min(lo[k], a["min"][k])
                    hi[k] = max(hi[k], a["max"][k])
        best = min(best, max(hi[k] - lo[k] for k in range(3)))
    return best if best < 1.0e9 else 0.8


def grow_species(mb, h, cx, cz, hs, ground, mats_by_name):
    """Three species of vine over the WHOLE landmass, one curve each.

    The root-mat layout seeds only where the material classifier already said
    VINE, which is a fifth of the map — everywhere else is bare. This seeds
    from every drawn cell instead, so the vines are the ground cover rather
    than a feature on it.

    Each species gets its OWN Random. Three fields sharing one stream are not
    three species, they are one species drawn three times, and the giveaway is
    that all three thin out in the same places.
    """
    out = []
    bound = smallest_machine_m()
    for name, seed, hexs, rad, length, share, per_cell in SPECIES:
        srng = random.Random(seed)
        mat = _vine_curve_mat("skin_" + name, hexs, 0.82,
                              tile=(10.0 if name != "large" else 7.0, 1.0))
        mats_by_name[name] = mat
        # bevel_depth is the species' MAXIMUM radius; the per-point radius
        # multiplier then rides between the two ends of its range.
        cu = VineCurves("vine_" + name, rad[1], 2 if name == "large" else 1, mat)
        cells = list(ground)
        srng.shuffle(cells)
        take = int(len(cells) * share)
        for i in cells[:take]:
            x0, y0 = i % cx, i // cx
            for _ in range(per_cell):
                w = srng.uniform(rad[0], rad[1])
                pts, radii, _a = vine_run(
                    srng, h, cx, cz, hs,
                    x0 + srng.uniform(-1.2, 1.2), y0 + srng.uniform(-1.2, 1.2),
                    srng.uniform(*length), w)
                cu.add(pts, radii)
                # Nodules only on the large species. On the other two they are
                # smaller than a texel in the bake and cost triangles to say
                # nothing.
                if name == "large" and srng.random() < 0.5:
                    k = srng.randint(1, max(1, len(pts) - 2))
                    q = pts[k]
                    mb.orb(VINE_MAT_SLOT, (q[0], q[1], q[2] + radii[k] * 0.4),
                           radii[k] * srng.uniform(1.2, 1.7), 7, 5,
                           lumps=0.25, seed=srng.random() * 40.0)
        # The tallest thing this species puts on the ground: the tube's own
        # diameter plus how far vine_run lifts it off the surface.
        tall = rad[1] * 2.0 + 0.04 + 0.12 * rad[1]
        print("PY: %-6s seed %-7d %s  r %.3f-%.3f m  %d splines  stands %.2f m"
              % (name, seed, hexs, rad[0], rad[1], cu.splines, tall))
        if name == "large":
            assert tall < bound * 0.85, (
                "large vine stands %.2f m against the smallest machine's "
                "%.2f m — it has to stay under it" % (tall, bound))
            print("PY: largest vine %.2f m against the smallest machine at "
                  "%.2f m — ok" % (tall, bound))
        out.append(cu)
    return out


class VineCurves:
    """One Blender CURVE holding many splines, bevelled into a real tube.

    REAL SPLINES, not a triangle list. Every vine used to be points and
    triangles emitted from Python — correct geometry that nobody could ever
    edit, because there was nothing in the .blend to grab hold of. These are
    curve objects: open the file, tab into one, and the vines are control
    points you can move, with the tube regenerating from them.

    One datablock per TIER rather than per vine. `bevel_depth` is a property of
    the curve, not of the spline, so each tier carries its own base thickness
    and the per-vine variation rides on the control points' own `radius`, which
    multiplies it. Four thousand curve objects is what killed the bake at 66
    minutes the first time; three is free.
    """

    def __init__(self, name, depth_m, sides_res, mat):
        self.cu = bpy.data.curves.new(name, 'CURVE')
        self.cu.dimensions = '3D'
        self.cu.bevel_depth = depth_m
        self.cu.bevel_resolution = sides_res
        self.cu.use_fill_caps = True
        self.cu.resolution_u = 1          # POLY splines: no subdivision wanted
        self.cu.materials.append(mat)
        self.depth = depth_m
        self.ob = bpy.data.objects.new(name, self.cu)
        bpy.context.collection.objects.link(self.ob)
        self.splines = 0

    def add(self, pts, radii):
        sp = self.cu.splines.new('POLY')
        sp.points.add(len(pts) - 1)
        for i, p in enumerate(pts):
            sp.points[i].co = (p[0], p[1], p[2], 1.0)
            # radius MULTIPLIES bevel_depth, so this is the swell the tube
            # already had, expressed as a ratio instead of in metres.
            sp.points[i].radius = max(0.02, radii[i] / self.depth)
        self.splines += 1
        return sp

    def to_mesh_object(self, name):
        """A mesh copy for the bake to fire at, leaving the curve editable.

        Cycles' selected-to-active bake wants mesh sources, so the curve cannot
        be a source itself. Converting rather than replacing means the .blend
        keeps both: the splines somebody can edit, and the geometry the bake
        actually read.
        """
        dg = bpy.context.evaluated_depsgraph_get()
        me = bpy.data.meshes.new_from_object(self.ob.evaluated_get(dg))
        ob = bpy.data.objects.new(name, me)
        bpy.context.collection.objects.link(ob)
        self.ob.hide_render = True
        self.ob.hide_viewport = True
        return ob


def grow_vine(curves, mb, slot, rng, h, cx, cz, hs, x0, y0, length, width,
              depth=0):
    """A vine AND what grows off it. Returns the trunk's points and radii.

    The trunk is a SPLINE on `curves` now; the nodules and pores stay triangle
    geometry, because a nodule is a blob and not a swept tube and there is
    nothing about it to edit.

    This is the difference between the first pass and reference 03. There, a
    vine is not a tube — it is a trunk that BRANCHES, with nodules swelling
    along it and glowing pores set into the swellings. A single swept tube can
    never look like that however it is tuned, because the structure is missing
    rather than the detail.
    """
    pts, radii, _ang = vine_run(rng, h, cx, cz, hs, x0, y0, length, width)
    curves.add(pts, radii)

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
            grow_vine(curves, mb, slot, rng, h, cx, cz, hs, q[0], q[1],
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
            base[i] += (hexcol(GROUND_SAND)[i] - base[i]) * _fit(sand, 0.30, 0.78) * 0.70
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
    # One scale every SCALE_M metres across the whole map.
    tiles = ((cx - 1.0) / SCALE_M, (cz - 1.0) / SCALE_M)
    high_ground = terrain(cx, cz, h, hs, void, "high_ground",
                          [_vertex_colour_mat("ground_painted",
                                              scale_tile=tiles)],
                          ground_paint, subdiv=GROUND_SUBDIV)

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
    curve_objs = []

    if WHOLE_MAP:
        # THREE SPECIES OVER THE WHOLE LANDMASS. Seeded from every drawn cell
        # rather than from the root-mat cells, so the vines ARE the ground
        # cover instead of a feature lying on it. See SPECIES and grow_species.
        ground_cells = [k for k in range(cx * cz) if h[k] >= void + 0.01]
        print("PY: %d drawn cells of %d to grow over" % (len(ground_cells),
                                                         cx * cz))
        skins = {}
        curve_objs = grow_species(mb, h, cx, cz, hs, ground_cells, skins)
        made = sum(c.splines for c in curve_objs)
        fine = mat_runs = 0
    else:
        # THE THREE TIERS, AS CURVES. See VineCurves: one datablock each, because
        # bevel_depth belongs to the curve and the per-vine swell rides on the
        # control points' radius.
        #
        # HALF THE THICKNESS THEY WERE. Every base radius below is the old one
        # times VINE_SCALE. The bevel resolution went UP at the same time — a
        # 12-sided tube at 10 cm costs the same triangles as a 6-sided one at
        # 20 cm did, and now that they are round the silhouette is worth having.
        # Their OWN materials, not the mesh slots. The curve material reads the
        # generated UV (see _vine_curve_mat); the MB geometry that shares these
        # slots — nodules, clumps — has no UV at all, so one material cannot serve
        # both without one of them sampling a texture at (0, 0) forever.
        vine_m = _vine_curve_mat("vine_skin", VINE_BODY, 0.80, tile=(10.0, 1.0))
        live_m = _vine_curve_mat("live_skin", LIVE_BODY, 0.70, GLOW, 2.5,
                                 tile=(10.0, 1.0))
        trunk_c = VineCurves("vine_trunks", 0.34 * VINE_SCALE, 2, vine_m)
        live_c = VineCurves("vine_live", 0.34 * VINE_SCALE, 2, live_m)
        runner_c = VineCurves("vine_runners", 0.11 * VINE_SCALE, 1, vine_m)
        filament_c = VineCurves("vine_filaments", 0.062 * VINE_SCALE, 1, vine_m)
        want_trunks = int(VINE_TARGET * VINE_COUNT_SCALE)
        made = 0
        for i in seeds:
            if made >= want_trunks:
                break
            if rng.random() > 0.55:
                continue
            x0, y0 = i % cx, i // cx
            # A bundle, not a single vine: the reference's web is bundles of about
            # four crests inside a 3.6 m envelope, which is what makes it BRAID.
            for _ in range(rng.randint(2, 4)):
                if made >= want_trunks:
                    break
                # One vine in six glows. The reference's live emerald roots are
                # 0.8-1.2% of area; the rest of the web is a pale unlit tube, and
                # making all of it a light source read as a neon scribble.
                live = rng.random() < 0.16
                pts, radii = grow_vine(live_c if live else trunk_c, mb,
                                       LIVE if live else VINE, rng, h, cx, cz,
                                       hs, x0 + rng.uniform(-1.8, 1.8),
                                       y0 + rng.uniform(-1.8, 1.8),
                                       rng.uniform(5.0, 12.0),
                                       rng.uniform(0.20, 0.50) * VINE_SCALE)
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
            if fine >= int(VINE_TARGET * VINE_COUNT_SCALE * 0.5):
                break
            if rng.random() > 0.45:
                continue
            x0, y0 = i % cx, i // cx
            pts, radii, _ = vine_run(rng, h, cx, cz, hs,
                                     x0 + rng.uniform(-2.4, 2.4),
                                     y0 + rng.uniform(-2.4, 2.4),
                                     rng.uniform(2.5, 6.0),
                                     rng.uniform(0.06, 0.16) * VINE_SCALE)
            runner_c.add(pts, radii)
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
        want_mat = int(VINE_TARGET * VINE_COUNT_SCALE * 1.5)
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
                                         rng.uniform(0.035, 0.09) * VINE_SCALE)
                filament_c.add(pts, radii)
                mat_runs += 1
        print("PY: %d filaments in the mat under them" % mat_runs)
        curve_objs = [trunk_c, live_c, runner_c, filament_c]

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

    # Mesh copies for the bake to fire at. The curve objects stay in the file,
    # hidden, so the splines remain there to edit; see VineCurves.to_mesh_object
    # for why the bake cannot read them directly.
    tris = mb.tris
    for c in curve_objs:
        ob = c.to_mesh_object(c.ob.name + "_mesh")
        tris += len(ob.data.polygons)
    print("PY: %s profile: %d vines and %d clumps; %d splines over %d curves; "
          "%d faces" % (PROFILE, made, dressed,
                        sum(c.splines for c in curve_objs), len(curve_objs),
                        tris))

    return low, high_ground


def _bake_depth(low, res_x, res_y, node, mat, sources):
    """How far the detail stands off the ground, in metres, as an 8-bit map.

    THE THIRD MAP. A normal map says which way a surface tilts and a colour map
    says what it is made of; neither says how FAR above the floor it is, and
    that is the one thing the ground needs to cast its own detail onto itself.
    A vine lying on the floor and a vine painted on the floor have identical
    normals.

    Cycles has no displacement bake, so this goes through POSITION — the world
    coordinate of the high-poly surface at each texel of the low-poly — into a
    FLOAT buffer, because the map is 150 m across and an 8-bit position bake
    would quantise the whole thing into six centimetre steps. The height above
    the ground is then that Z minus the heightfield's own Z at the same texel,
    which is exact rather than inferred: the unwrap is (x / width, z / depth),
    so a texel's map coordinate is known in closed form.
    """
    img = bpy.data.images.new("bake_pos", res_x, res_y, alpha=False,
                              float_buffer=True)
    node.image = img
    mat.node_tree.nodes.active = node
    bpy.ops.object.select_all(action='DESELECT')
    for o in sources:
        o.select_set(True)
    low.select_set(True)
    bpy.context.view_layer.objects.active = low
    bpy.ops.object.bake(type='POSITION')

    px = np.array(img.pixels[:], dtype=np.float32).reshape(res_y, res_x, 4)
    meta, cx, cz, h, _mat = load_map()
    hs = meta["height_scale_m"]
    hf = np.array(h, dtype=np.float32).reshape(cz, cx)
    # The texel centres, in map coordinates. Row 0 of a Blender image is V = 0,
    # which is map y = 0, so no flip is needed — but it is the kind of thing
    # that is silently upside down for a week, so it is asserted below.
    ys = (np.arange(res_y) + 0.5) / res_y * (cz - 1.0)
    xs = (np.arange(res_x) + 0.5) / res_x * (cx - 1.0)
    gx, gy = np.meshgrid(xs, ys)
    # THE BAKE'S SCALE IS NOT TRUSTED, IT IS MEASURED.
    #
    # This POSITION pass comes back uniformly four times too large in this
    # Blender build — texel centres that should read x = 37.5, 74.8, 112.0 read
    # 149.95, 299.15, 448.04. Dividing by four would work today and break
    # silently the day that changes, and a depth map wrong by a constant looks
    # exactly like a map of taller vines.
    #
    # So the factor is recovered from the data: every texel's true world X and
    # Y are known in closed form, because the unwrap is (x / width, z / depth).
    # Fitting the ratio on both axes independently and requiring them to agree
    # turns an unexplained constant into a checked one — if the bake ever comes
    # back correctly scaled this reads 1.0 and nothing else has to change.
    solid = (gx > 5.0) & (gy > 5.0) & (px[..., 0] > 1.0) & (px[..., 1] > 1.0)
    assert solid.sum() > 64, "position bake produced almost nothing to fit"
    kx = float(np.median(px[..., 0][solid] / gx[solid]))
    ky = float(np.median(px[..., 1][solid] / gy[solid]))
    assert abs(kx - ky) < 0.02 * max(kx, ky), (
        "the position bake's X and Y scales disagree (%.4f vs %.4f) — it is "
        "not a uniform scale and this correction does not apply" % (kx, ky))
    k = 0.5 * (kx + ky)
    px = px / k

    # THE SURFACE IS SAMPLED AT THE BAKED POSITION, not at the texel's nominal
    # one. A cage ray leaves along the LOW-POLY's normal, so on steep ground it
    # lands a metre or two downhill of the texel it belongs to; measuring the
    # height against where the texel nominally is would read that lateral slide
    # as relief and put a phantom bank on every slope. Against where the ray
    # actually landed, the slide cancels exactly.
    bx = np.clip(px[..., 0], 0.0, cx - 1.001)
    by = np.clip(px[..., 1], 0.0, cz - 1.001)
    x0 = bx.astype(np.int32)
    y0 = by.astype(np.int32)
    fx = bx - x0
    fy = by - y0
    surface = ((hf[y0, x0] * (1 - fx) + hf[y0, x0 + 1] * fx) * (1 - fy)
               + (hf[y0 + 1, x0] * (1 - fx) + hf[y0 + 1, x0 + 1] * fx) * fy) * hs

    # A ray that hit nothing comes back at the origin. Alpha cannot say so —
    # the image is opaque, so it is 1 even where nothing was hit.
    hit = (px[..., 0] > 0.01) | (px[..., 1] > 0.01)
    inside = float(np.mean((px[..., 0] <= cx) & (px[..., 1] <= cz)))
    assert inside > 0.95, (
        "only %.0f%% of corrected positions land inside the map — the scale "
        "fit is wrong" % (100.0 * inside))
    print("PY: position bake scale %.4f (x %.4f, y %.4f); %.0f%% of corrected "
          "positions land inside the map" % (k, kx, ky, 100.0 * inside))
    above = np.where(hit, px[..., 2] - surface, 0.0)
    clipped = float(np.mean(above > DEPTH_RANGE_M))
    depth = np.clip(above / DEPTH_RANGE_M, 0.0, 1.0)
    out = np.stack([depth] * 3 + [np.ones_like(depth)], -1)
    dimg = bpy.data.images.new("bake_depth", res_x, res_y, alpha=False)
    dimg.pixels = out.reshape(-1).tolist()
    dimg.filepath_raw = OUT_D
    dimg.file_format = 'PNG'
    dimg.save()
    lit = above[hit]
    print("PY: depth %.0f%% of texels hit; height above ground median %.3f m, "
          "95th %.3f m, 99.9th %.3f m; %.2f%% clips the %.2f m range"
          % (100.0 * hit.mean(),
             float(np.median(lit)) if lit.size else 0.0,
             float(np.percentile(lit, 95)) if lit.size else 0.0,
             float(np.percentile(lit, 99.9)) if lit.size else 0.0,
             100.0 * clipped, DEPTH_RANGE_M))
    assert clipped < 0.02, (
        "%.1f%% of the depth map clips — DEPTH_RANGE_M is too small for what "
        "the scene actually grows" % (100.0 * clipped))
    # A depth map that is all zero is a bake that silently did nothing, and it
    # looks exactly like a map of perfectly flat ground.
    assert lit.size and float(np.percentile(lit, 99)) > 0.05, \
        "depth bake produced no relief — the POSITION pass found nothing"
    print("PY: wrote %s" % OUT_D)


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
    _bake_depth(low, res_x, res_y, node, mat, sources)

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
    # THE SPLINES ARE THE DELIVERABLE, not a step on the way to one. A run that
    # baked correct maps off converted meshes and saved a file with no curves
    # in it would look like a complete success from every other output here, so
    # it is asserted rather than assumed.
    curves = [o for o in bpy.data.objects if o.type == 'CURVE']
    total = sum(len(o.data.splines) for o in curves)
    assert curves and total > 0, "no editable curves left in the scene"
    print("PY: %d curve objects, %d splines, %d control points — editable"
          % (len(curves), total,
             sum(len(sp.points) for o in curves for sp in o.data.splines)))
    bpy.ops.wm.save_as_mainfile(filepath=BLEND)
    print("PY: wrote %s" % BLEND)


main()
