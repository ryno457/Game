"""SENTINEL — biodome dressing: the living architecture of the map.

Six props, one .glb each, scattered across the terrain by MultiMesh in Godot.
Reference is the bioluminescent-cavern painting the brief supplied: pale ribbed
arches, glowing teal and amber orbs, snaking green tendrils, purple lobed
growths, coral fans and dark rock.

    ~/.cache/blender-venv/bin/python tools/blender/build_flora.py [out_dir]

Conventions (same as the machine pass):
  * metres, Z-up in Blender; the glTF exporter converts to Y-up for Godot
  * origin at the ground contact point (lowest geometry sits at z = 0)
  * solid colours + emission only, no UVs, no textures
  * fully deterministic — no random calls, no timestamps

ONE MESH PER FILE, deliberately. MultiMesh renders a single Mesh (all of its
surfaces) across every instance, so a prop split into parented child nodes
could not be instanced and would cost a draw call each. Several hundred of
these have to sit on the map at once on a Mali-G68, so they are built as one
mesh with a handful of material surfaces and nothing else.

What this is NOT: the reference painting has millions of implied polygons and
volumetric god-rays. This is the mobile reading of it — silhouette, palette and
glow, at a few hundred triangles a piece.
"""
import bpy, sys, os, math, random, struct, json

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mathutils import Matrix, Vector
from _bl import script_args
import _organic as og
from _ao import bake_vertex_ao

argv = script_args()
OUT = os.path.abspath(argv[0] if argv else "models")
os.makedirs(OUT, exist_ok=True)

TAU = math.tau


# --- palette ----------------------------------------------------------------
# glTF baseColorFactor / emissiveFactor are LINEAR; the hexes below are sRGB.
def _s2l(b):
    c = b / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def hexcol(h):
    return tuple(_s2l(int(h[i:i + 2], 16)) for i in (0, 2, 4)) + (1.0,)


# slot index -> (name, base hex, emission hex or None, emission strength)
# Sampled toward docs/reference/02-ui-mockup-landscape.png, whose floor carries
# mossy greens, warm rust and violet where reference 01 is almost all teal.
#
# The old values were near-black: husk #26362f and stone #2b3036 are luma 0.04
# and 0.03. Under the moon rig every prop on the map rendered as a silhouette
# with no readable form at all — the "black plants" complaint, and it was an
# albedo problem rather than a lighting one. Nothing here is light grey, which
# belongs to the machines.
# MEASURED AGAINST REFERENCE 01, not chosen. Every value here was too light
# and too saturated, and the frame said so: median saturation 0.61 against the
# reference's 0.52, with the props the loudest thing in it — a pale olive arch
# at luma 0.61 standing on ground at 0.22, and mossy green tendrils at hue 114
# on a map whose median hue is 174.
#
# The dressing still carries the hue variety (see docs/reference/README.md —
# the ground follows 01, the dressing supplies 02 and 03's colour). What it
# must not do is carry it at a value and a chroma nothing in the reference
# reaches. The ROOTS in particular are teal in 01, not green; green belongs to
# the moss clumps, which are small enough not to move the median.
# BEIGE IS AN ACCENT, and it is the one the earlier measurement missed.
#
# "Every warm hue in reference 01 is 0.38% of the image" was measured over
# SATURATED pixels only. Beige is desaturated warm, so it fell straight through
# that test — and it is what the boulder clusters, the coral fans, the bridge
# and the tall pale structure in reference 01 actually are. Measured properly
# they are 0.7% of area at rgb(92, 79, 69), saturation 0.24, luma 0.32: small,
# but the only warm thing in a teal field, so they are where the eye lands.
#
# So the ROCK and the hard growths go beige and the roots stay teal. Reference
# 01's web is teal; its rubble is not.
PALETTE = [
    ("bone",     "6e6153", None,     0.0),   # ribbed arch: pale beige stone
    ("husk",     "2e5750", None,     0.0),   # tendril skin — TEAL, as ref 01
    ("flesh",    "5c3d7d", None,     0.0),   # purple lobed growth
    ("stone",    "5e564a", None,     0.0),   # rock: grey-beige, as ref 01's
    ("glow_t",   "17463f", "7fe8cf", 5.0),   # teal bioluminescence
    ("glow_p",   "301848", "a97fe0", 4.0),   # violet bioluminescence
    ("glow_a",   "543009", "f0b070", 4.0),   # amber ocelli
    ("sand",     "7a6b56", None,     0.0),   # the beige growths: coral, pods
]
BONE, HUSK, FLESH, STONE, GLOW_T, GLOW_P, GLOW_A, SAND = range(8)


def set_in(bsdf, name, value):
    if name in bsdf.inputs:
        bsdf.inputs[name].default_value = value


def make_materials():
    mats = []
    for name, base, emis, strength in PALETTE:
        m = bpy.data.materials.new("bio_" + name)
        m.use_nodes = True
        b = m.node_tree.nodes["Principled BSDF"]
        set_in(b, "Base Color", hexcol(base))
        set_in(b, "Roughness", 0.55 if emis else 0.82)
        set_in(b, "Metallic", 0.0)
        if emis:
            set_in(b, "Emission Color", hexcol(emis))
            set_in(b, "Emission Strength", strength)
        mats.append(m)
    return mats


def xform(loc=(0, 0, 0), rot=(0, 0, 0), scale=1.0):
    return (Matrix.Translation(Vector(loc))
            @ Matrix.Rotation(rot[2], 4, 'Z')
            @ Matrix.Rotation(rot[1], 4, 'Y')
            @ Matrix.Rotation(rot[0], 4, 'X')
            @ Matrix.Scale(scale, 4))


class MB:
    """Accumulates triangles + per-triangle material index.

    OPTIONALLY per-vertex colour as well. A material slot is one flat colour
    over everything assigned to it, which is all a 500-triangle prop needs; the
    detail bake does not, because there a vine is one of four thousand and they
    cannot all be the same teal. `col` takes a flat colour for the whole
    primitive and `cols` a list, one per vertex, for a gradient along it.

    Props pass neither and get no colour attribute at all, so the vertex-AO
    bake still owns COLOR_0 on the exported assets exactly as before.
    """

    def __init__(self):
        self.v, self.f, self.m = [], [], []
        self.c = []
        self.painted = False

    def add(self, verts, tris, mat, M=None, col=None, cols=None):
        off = len(self.v)
        if M is None:
            self.v.extend(tuple(p) for p in verts)
        else:
            self.v.extend(tuple(M @ Vector(p)) for p in verts)
        if cols is not None:
            self.c.extend(tuple(c) for c in cols)
            self.painted = True
        elif col is not None:
            self.c.extend([tuple(col)] * len(verts))
            self.painted = True
        else:
            self.c.extend([(1.0, 1.0, 1.0, 1.0)] * len(verts))
        for t in tris:
            self.f.append(tuple(off + i for i in t))
            self.m.append(mat)

    def tube(self, mat, points, radii, sides=7, col=None, ring_cols=None, **kw):
        """`ring_cols` is one colour per POINT; tube vertices are ring-major, so
        it is expanded here rather than at every call site."""
        v, t = og.tube(points, radii, sides, **kw)
        cols = None
        if ring_cols is not None:
            caps_extra = len(v) - len(points) * sides
            cols = [ring_cols[min(i // sides, len(ring_cols) - 1)]
                    for i in range(len(points) * sides)]
            cols += [ring_cols[-1]] * max(0, caps_extra)
        self.add(v, t, mat, col=col, cols=cols)

    def orb(self, mat, at, r, segs=8, rings=5, col=None, **kw):
        v, t = og.sphere(r, segs, rings, **kw)
        self.add(v, t, mat, xform(at), col=col)

    def shard(self, mat, at, r, h, sides=6, rot=(0, 0, 0), col=None, **kw):
        v, t = og.shard(r, h, sides, **kw)
        self.add(v, t, mat, xform(at, rot), col=col)

    def ground(self):
        """Drop the whole prop so its lowest vertex sits exactly on z = 0.

        Done here rather than by hand per prop: a tube foot and a squashed orb
        both dip below their nominal origin by their own radius, and eyeballing
        that correction six times is how three of the machine assets ended up
        7-17 cm underground in the last pass.
        """
        low = min(p[2] for p in self.v)
        self.v = [(x, y, z - low) for (x, y, z) in self.v]
        return self

    @property
    def tris(self):
        return len(self.f)


def make_object(name, mb, mats, smooth=True):
    me = bpy.data.meshes.new(name + "_mesh")
    me.from_pydata(mb.v, [], mb.f)
    me.update()
    if mb.painted:
        # Only when something actually painted. An empty attribute here would
        # become the active colour layer and the vertex-AO bake would then have
        # to fight it for COLOR_0 on every prop.
        attr = me.color_attributes.new("paint", 'FLOAT_COLOR', 'POINT')
        for i, c in enumerate(mb.c):
            attr.data[i].color = c
        me.color_attributes.active_color = attr
        me.color_attributes.render_color_index = me.color_attributes.find("paint")
    for m in mats:
        me.materials.append(m)
    for i, mi in enumerate(mb.m):
        me.polygons[i].material_index = mi
    # Grown things are smooth — a flat-shaded tube at seven sides reads as a
    # pipe. Rock is not a grown thing and passes smooth=False.
    for poly in me.polygons:
        poly.use_smooth = smooth
    ob = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(ob)
    return ob


def new_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    return make_materials()


# =============================================================================
# ARCH — the ribbed bone gateway. The landmark prop; everything else dresses it
# =============================================================================
def build_arch(mats):
    """A SPIRE TOWER, as in reference 03 — not an arch.

    It was an arch: span 2.9 and rise 4.1, so 5.8 m wide by 4.1 m tall, a ratio
    of 0.71:1. Measured off the reference, the same class of object there is the
    dominant VERTICAL element at about 3.85:1 — roughly 12-19 m tall on a 3-5 m
    footprint. A squat hoop where the painting has a tower.

    At PropScatter's 1.30-2.40 scale the proportions below land at 9-17 m tall
    on a 2.3-4.3 m base, which is that, and it is the cheapest verticality
    available while the ravine is unbuilt: the map is a heightfield with gentle
    domes, so anything that stands UP has to be a prop.
    """
    mb = MB()
    rise, foot = 7.2, 0.95

    # Three trunks twisting up around a common axis, splaying at the foot and
    # converging near the top. The twist is what makes the fenestration read
    # from any angle instead of only side-on.
    trunks = []
    for k in range(3):
        a0 = k * math.tau / 3.0
        pts, radii = [], []
        n = 13
        for i in range(n):
            t = i / (n - 1.0)
            a = a0 + t * 1.5                       # the twist
            r = foot * (1.0 - 0.72 * t) + 0.10
            pts.append((math.cos(a) * r, math.sin(a) * r, t * rise))
            # Swell low, pinch at the waist, flare again at the crown.
            sw = 0.52 + 0.48 * math.sin(t * math.pi * 1.7 + 0.5)
            radii.append(0.135 * sw * (1.0 - 0.45 * t) + 0.045)
        radii[0] *= 2.1                            # splayed foot
        mb.tube(BONE, pts, radii, 7, ridge=0.24, seed=k * 3.0)
        trunks.append(pts)

    # Cross ribs between the trunks. The gaps ARE the fenestration: a real hole
    # would cost more triangles than the whole prop is allowed.
    for i in range(2, 12, 2):
        for a, b in ((0, 1), (1, 2), (2, 0)):
            p, q = trunks[a][i], trunks[b][i]
            mb.tube(BONE, [p, q], [0.052, 0.052], 5, caps=True, seed=i + a)

    # A crown: the spike cluster every tower in the reference carries.
    for k in range(3):
        a = k * math.tau / 3.0 + 0.6
        base = (math.cos(a) * 0.16, math.sin(a) * 0.16, rise * 0.97)
        tip = (math.cos(a) * 0.40, math.sin(a) * 0.40, rise * 1.28)
        mb.tube(BONE, [base, tip], [0.075, 0.012], 5, caps=True, seed=k)

    # Ocelli, the glowing eye-spots, set ON the trunks and up the height so the
    # tower reads as lit from top to bottom rather than only at its foot.
    for i, mat, r in ((3, GLOW_A, 0.13), (5, GLOW_T, 0.15), (7, GLOW_A, 0.12),
                      (9, GLOW_T, 0.13), (11, GLOW_A, 0.10)):
        p = trunks[i % 3][i]
        mb.orb(mat, (p[0] * 1.25, p[1] * 1.25, p[2]), r, 7, 5, lumps=0.18,
               seed=float(i))
    return mb


def build_tendril(mats):
    mb = MB()
    pts, radii = [], []
    n = 16
    for i in range(n):
        t = i / (n - 1.0)
        pts.append((math.sin(t * 5.4) * 1.5 + t * 2.4 - 1.2,
                    math.cos(t * 4.1) * 1.1 - 0.4,
                    0.22 + math.sin(t * 2.6) * 0.34 + t * 0.30))
        radii.append(0.20 * (1.0 - 0.55 * t) + 0.05)
    mb.tube(HUSK, pts, radii, 7, ridge=0.13, seed=1.0)

    # A second, thinner runner braiding over the first.
    p2 = [(p[0] + 0.30, p[1] + 0.34, p[2] + 0.16 * math.sin(i * 0.9))
          for i, p in enumerate(pts[2:14])]
    mb.tube(HUSK, p2, [0.10] * len(p2), 5, ridge=0.16, seed=7.0)

    # Nodules along the spine. This is where the light in that painting lives —
    # not on the vine, but in beads strung along it.
    for i in range(2, n - 1, 3):
        p = pts[i]
        mb.orb(GLOW_T, (p[0], p[1], p[2] + radii[i] * 0.75), 0.115, 7, 4,
               lumps=0.16, seed=i)
    for i in (4, 11):
        p = pts[i]
        mb.orb(GLOW_P, (p[0] - 0.22, p[1] - 0.20, p[2] + 0.10), 0.085, 6, 4, seed=i)
    return mb


# =============================================================================
# CORAL — the branching fan that fills the mid-ground
# =============================================================================
def build_coral(mats):
    mb = MB()
    stem = [(0.0, 0.0, 0.0), (0.04, 0.05, 0.36), (0.0, -0.03, 0.72)]
    mb.tube(SAND, stem, [0.17, 0.13, 0.10], 6, ridge=0.08)
    tips = []
    for k in range(5):
        a = -0.9 + k * 0.45
        lean = 0.62 + 0.10 * (k % 3)
        top = (math.sin(a) * lean, math.cos(a) * lean * 0.55, 1.22 + 0.16 * (k % 2))
        mid = og.lerp3(stem[-1], top, 0.55)
        mid = (mid[0] * 0.75, mid[1] * 0.75, mid[2] + 0.10)
        mb.tube(SAND, [stem[-1], mid, top], [0.10, 0.07, 0.035], 5, seed=k)
        tips.append(top)
    for k, t in enumerate(tips):
        mb.orb(GLOW_T if k % 2 == 0 else GLOW_P, t, 0.10, 6, 4, lumps=0.2, seed=k)
    mb.orb(SAND, (0.0, 0.0, 0.07), 0.30, 7, 4, squash=0.4, lumps=0.25)
    return mb


# =============================================================================
# PODS — a low clutter cluster of glowing bulbs on stalks
# =============================================================================
def build_pods(mats):
    mb = MB()
    spots = [(-0.34, 0.12, 0.46, GLOW_T, 0.17),
             (0.28, -0.22, 0.62, GLOW_A, 0.145),
             (0.06, 0.38, 0.34, GLOW_P, 0.125),
             (0.44, 0.22, 0.28, GLOW_T, 0.10),
             (-0.20, -0.36, 0.24, GLOW_T, 0.085)]
    for x, y, z, mat, r in spots:
        mb.tube(SAND, [(x * 0.35, y * 0.35, 0.0), (x * 0.8, y * 0.8, z * 0.55),
                       (x, y, z - r * 0.5)], [0.055, 0.042, 0.030], 5, seed=x)
        mb.orb(mat, (x, y, z), r, 7, 5, lumps=0.14, seed=y)
    mb.orb(SAND, (0.0, 0.0, 0.05), 0.34, 7, 4, squash=0.30, lumps=0.30)
    return mb


# =============================================================================
# BRAIN — the purple lobed mass from the top-left of the reference
# =============================================================================
def build_brain(mats):
    mb = MB()
    lobes = [(0.0, 0.0, 0.52, 0.72), (-0.72, 0.30, 0.40, 0.50),
             (0.66, 0.26, 0.44, 0.54), (0.16, -0.70, 0.36, 0.46),
             (-0.30, -0.52, 0.30, 0.38), (0.52, -0.40, 0.28, 0.34)]
    for x, y, z, r in lobes:
        mb.orb(FLESH, (x, y, z), r, 9, 6, squash=0.72, lumps=0.20, seed=x * 3.0)
    # The glowing veins that run between the lobes.
    for a in range(len(lobes) - 1):
        p = lobes[a]
        q = lobes[a + 1]
        mb.tube(GLOW_P, [(p[0], p[1], p[2] + p[3] * 0.55),
                         ((p[0] + q[0]) * 0.5, (p[1] + q[1]) * 0.5, p[2] + 0.30),
                         (q[0], q[1], q[2] + q[3] * 0.55)],
                [0.050, 0.065, 0.050], 5, seed=a)
    mb.orb(GLOW_P, (0.0, 0.0, 1.02), 0.16, 7, 4, lumps=0.2)
    return mb


# =============================================================================
# SPIRE — dark rock, the only thing in the biodome that is not alive
# =============================================================================
def build_spire(mats):
    """A rock needle. Taller and thinner than it was, for the same reason the
    arch changed: with the ravine unbuilt, props are the only verticality the
    map has, and a 2.35 m stub does not break a skyline."""
    mb = MB()
    mb.shard(STONE, (0.0, 0.0, 0.0), 0.52, 4.60, 7, taper=0.11, lean=0.26, seed=1.0)
    mb.shard(STONE, (0.44, 0.19, 0.0), 0.30, 2.55, 6, taper=0.16, lean=-0.18, seed=4.0)
    mb.shard(STONE, (-0.36, -0.25, 0.0), 0.24, 1.60, 5, taper=0.22, lean=0.13, seed=9.0)
    # Veins of light in the rock, so it belongs to this map and not another.
    mb.tube(GLOW_T, [(-0.10, 0.18, 0.15), (0.06, 0.22, 1.60), (0.18, 0.12, 2.90)],
            [0.045, 0.034, 0.018], 5)
    mb.orb(GLOW_T, (0.12, 0.16, 2.05), 0.085, 6, 4, lumps=0.2, seed=3.0)
    return mb


def _slab(mb, mat, at, size, rot=(0, 0, 0), chip=0.10, seed=0.0):
    """One weathered rectangular block, origin at the centre of its base.

    Eight vertices, jittered. A clean box reads as a crate; the jitter is what
    makes it stone, and it is cheaper than any amount of bevelling. Deliberately
    NOT smooth-shaded — see PROPS: a stone slab with smoothed normals reads as
    a melted candle.
    """
    hx, hy, hz = size[0] * 0.5, size[1] * 0.5, size[2]
    rnd = random.Random(int(seed * 1000) + 77)
    v = []
    for sz in (0.0, 1.0):
        for sx, sy in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
            j = chip * (0.4 + 0.6 * sz)     # the top is the weathered end
            v.append((sx * hx * (1.0 + rnd.uniform(-j, j)),
                      sy * hy * (1.0 + rnd.uniform(-j, j)),
                      sz * hz + rnd.uniform(-j, j) * hz * 0.12))
    t = [(0, 1, 2), (0, 2, 3),          # base
         (4, 6, 5), (4, 7, 6),          # top
         (0, 4, 5), (0, 5, 1), (1, 5, 6), (1, 6, 2),
         (2, 6, 7), (2, 7, 3), (3, 7, 4), (3, 4, 0)]
    mb.add(v, t, mat, xform(at, rot))


def build_ruin(mats):
    """An alien ruin: tilted monoliths and a broken wall, from reference 02.

    THIS IS NOT A PLANT, and that is the point. Reference 02's verticality
    comes from angular built things — slabs, broken walls, leaning monoliths
    standing along the ridges — and the map has none of that. Every prop it
    carries grew: tendrils, coral, pods, brains, needles. A landscape made
    entirely of grown forms has no straight line anywhere in it, which is
    exactly what "the landscape is flat" describes from overhead, because
    nothing casts a hard vertical edge.

    Stone, not light grey. Grey belongs to the machines: a ruin at the
    machines' value would camouflage a unit standing beside it, which is the
    same rule the rock ground material follows.
    """
    mb = MB()
    # The tall one. Leaning, because a plumb monolith reads as placed and a
    # leaning one reads as abandoned.
    _slab(mb, STONE, (0.0, 0.0, -0.10), (1.35, 0.62, 5.40),
          rot=(0.10, 0.055, 0.32), chip=0.13, seed=0.4)
    # Its broken-off top, fallen at the foot. Same stone, so the eye reads the
    # pair as one object that failed rather than two objects.
    _slab(mb, STONE, (1.42, 0.50, 0.0), (1.15, 0.58, 0.95),
          rot=(1.31, 0.18, -0.55), chip=0.16, seed=1.7)
    # A second, shorter monolith set back and turned the other way.
    _slab(mb, STONE, (-1.35, 0.85, -0.05), (0.95, 0.52, 3.20),
          rot=(-0.13, 0.09, -0.74), chip=0.12, seed=2.9)
    # The wall it all belonged to: a low run with a gap bitten out of it.
    _slab(mb, STONE, (-0.35, -1.55, -0.05), (3.10, 0.48, 1.45),
          rot=(0.02, -0.035, 0.12), chip=0.10, seed=3.6)
    _slab(mb, STONE, (2.05, -1.35, -0.05), (1.20, 0.46, 0.80),
          rot=(0.05, 0.12, 0.26), chip=0.18, seed=4.3)
    # Rubble at the base, which is what tells you it is a ruin and not a shape.
    rnd = random.Random(8)
    for _ in range(5):
        a = rnd.uniform(0, math.tau)
        d = rnd.uniform(0.9, 2.6)
        mb.shard(STONE, (math.cos(a) * d, math.sin(a) * d, 0.0),
                 rnd.uniform(0.16, 0.34), rnd.uniform(0.25, 0.55), 5,
                 rot=(rnd.uniform(0.3, 1.2), 0.0, a), taper=0.5,
                 seed=rnd.random() * 20.0)
    # Light in the cracks. The ruin belongs to THIS map, and the same teal in
    # the seams is what says so — the rock spire carries it for the same reason.
    mb.tube(GLOW_T, [(-0.16, 0.10, 0.35), (-0.05, 0.16, 2.30), (0.10, 0.22, 4.30)],
            [0.040, 0.030, 0.016], 5)
    mb.orb(GLOW_T, (-0.02, 0.18, 1.35), 0.075, 6, 4, lumps=0.25, seed=6.0)
    mb.orb(GLOW_T, (-1.28, 0.92, 2.05), 0.065, 6, 4, lumps=0.25, seed=11.0)
    return mb


# name, builder, triangle budget, smooth-shaded, AO reach in metres
#
# Rock is FLAT shaded. Everything else grew, and grown things are smooth; a
# stone splinter with smoothed normals reads as a melted candle, which is what
# the first pass shipped.
PROPS = [
    ("flora_arch", build_arch, 1400, True, 2.2),
    ("flora_tendril", build_tendril, 620, True, 1.2),
    ("flora_coral", build_coral, 520, True, 1.0),
    ("flora_pods", build_pods, 420, True, 0.8),
    ("flora_brain", build_brain, 900, True, 1.6),
    ("rock_spire", build_spire, 200, False, 1.8),
    ("alien_ruin", build_ruin, 900, False, 2.6),
]

## Material slots left at full brightness by the AO bake. COLOR_0 multiplies
## base colour, and a light source with occlusion baked into it reads as a
## dirty bulb rather than a glowing one.
GLOWING = (GLOW_T, GLOW_P, GLOW_A)


# --- export + audit ---------------------------------------------------------
## Metres of surface one tile of the scale map covers on a PROP. The ground
## uses 5 m (detail_source.SCALE_M) because it is a floor seen at a distance;
## a plant is a small thing close to the same camera, so its skin has to be
## finer or one scale swallows a whole coral fan.
UV_TILE_M = 1.2


def unwrap(obj):
    """Give a prop a UV map, so the shared scale texture has somewhere to land.

    These assets have never had UVs: this project had no textures at all when
    they were written, and COLOR_0 carried everything. The seamless scale map
    changes that — the ground, the vines and the structures are meant to read
    as one organism's skin, and a texture needs a coordinate.

    SMART PROJECT, not a cylinder or a box. A coral fan, a lumpy brain and a
    slab of ruin have nothing in common to project along, and the pattern is
    isotropic so the only thing that matters is that the islands are the right
    SIZE relative to each other — which is exactly what an angle-based unwrap
    with area-weighted packing gives. A tiny island_margin because these are
    sampled with repeat, not packed into an atlas: the map tiles, so islands
    running off the edge is not a defect.
    """
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.smart_project(angle_limit=1.15, island_margin=0.002,
                             correct_aspect=True, scale_to_bounds=False)
    bpy.ops.object.mode_set(mode='OBJECT')
    _uv_to_metres(obj, UV_TILE_M)


def _uv_to_metres(obj, tile_m):
    """Rescale a packed unwrap so one UV unit is `tile_m` of real surface.

    smart_project packs every object's islands into 0..1, which means a 9.3 m
    arch and an 80 cm pod come out with the SAME number of UV units across
    them. Sampled with a tiling texture that makes the arch's scales twelve
    times the size of the pod's, and the two stop looking like the same
    creature — which is the entire point of them sharing a skin.

    The fix is a measurement, not a guess: take the ratio of world length to UV
    length over every edge, use the median (islands and seams make the mean
    useless), and scale the whole layout by it. The texture repeats, so running
    past 1.0 costs nothing.
    """
    me = obj.data
    uvs = me.uv_layers.active.data
    ratios = []
    for poly in me.polygons:
        n = poly.loop_total
        for k in range(n):
            a = poly.loop_start + k
            b = poly.loop_start + (k + 1) % n
            wa = me.vertices[me.loops[a].vertex_index].co
            wb = me.vertices[me.loops[b].vertex_index].co
            du = (uvs[a].uv - uvs[b].uv).length
            if du > 1e-6:
                ratios.append((wa - wb).length / du)
    if not ratios:
        return
    ratios.sort()
    metres_per_uv = ratios[len(ratios) // 2]
    k = metres_per_uv / tile_m
    for d in uvs:
        d.uv = (d.uv[0] * k, d.uv[1] * k)


def export_glb(path):
    # export_vertex_color='ACTIVE' forces COLOR_0 out even though no material
    # node reads it. The default ('MATERIAL') exports vertex colours only when
    # the shader graph uses them, and these materials deliberately do not —
    # Godot applies COLOR_0 itself on import.
    kwargs = dict(filepath=path, export_format='GLB', export_apply=True,
                  export_yup=True, export_materials='EXPORT', use_selection=False)
    try:
        bpy.ops.export_scene.gltf(export_vertex_color='ACTIVE', **kwargs)
    except TypeError:
        bpy.ops.export_scene.gltf(**kwargs)


def read_glb(path):
    with open(path, "rb") as f:
        magic, ver, _total = struct.unpack("<4sII", f.read(12))
        assert magic == b"glTF", "not a glb: %s" % path
        assert ver == 2, "glTF version %d" % ver
        n, kind = struct.unpack("<II", f.read(8))
        assert kind == 0x4E4F534A, "first chunk is not JSON"
        return json.loads(f.read(n).decode("utf-8"))


def audit(path, budget):
    """Assert what was promised, against the file that was actually written.

    Triangle count, one mesh, ground contact and an emissive surface — that
    last one because a prop in this biodome that does not glow is a bug you
    will not see until the map is lit.
    """
    doc = read_glb(path)
    meshes = doc.get("meshes", [])
    assert len(meshes) == 1, "%s: %d meshes, MultiMesh needs exactly 1" % (path, len(meshes))

    colours = all("COLOR_0" in prim["attributes"]
                  for prim in meshes[0]["primitives"])
    # UVs are not optional any more: the scale map is sampled through them, and
    # a prop exported without one samples texel (0, 0) over its whole surface —
    # a flat wash that looks like a lighting bug, not a missing unwrap.
    uvs = all("TEXCOORD_0" in prim["attributes"]
              for prim in meshes[0]["primitives"])
    tris = 0
    lo = [float("inf")] * 3
    hi = [float("-inf")] * 3
    for prim in meshes[0]["primitives"]:
        assert prim.get("mode", 4) == 4, "non-triangle primitive"
        tris += doc["accessors"][prim["indices"]]["count"] // 3
        acc = doc["accessors"][prim["attributes"]["POSITION"]]
        for k in range(3):
            lo[k] = min(lo[k], acc["min"][k])
            hi[k] = max(hi[k], acc["max"][k])

    emissive = 0
    for m in doc.get("materials", []):
        e = m.get("emissiveFactor", [0, 0, 0])
        if max(e) > 0.0 or "KHR_materials_emissive_strength" in m.get("extensions", {}):
            emissive += 1

    # glTF is Y-up: ground contact is min Y, not min Z.
    return {
        "tris": tris, "budget": budget, "emissive": emissive, "colours": colours,
        "ground": lo[1], "size": tuple(hi[k] - lo[k] for k in range(3)),
        "surfaces": len(meshes[0]["primitives"]), "uvs": uvs,
    }


def main():
    print("SENTINEL — biodome dressing\n")
    rows, bad = [], 0
    for name, fn, budget, smooth, reach in PROPS:
        mats = new_scene()
        mb = fn(mats).ground()
        obj = make_object(name, mb, mats, smooth)
        unwrap(obj)
        mean_occ = bake_vertex_ao(obj, rays=12, reach=reach,
                                  unoccluded_materials=GLOWING)
        path = os.path.join(OUT, name + ".glb")
        export_glb(path)
        a = audit(path, budget)
        a["occ"] = mean_occ
        # A bake that produced no occlusion at all is a bake that silently did
        # nothing — a wrong reach, a broken BVH, a mesh with no interior.
        ok = (a["tris"] <= budget and a["emissive"] > 0 and abs(a["ground"]) < 0.02
              and a["colours"] and a["uvs"] and mean_occ > 0.01)
        bad += 0 if ok else 1
        rows.append((name, a, ok))
        print("  %s  %-14s %5d / %-5d tris  %d surf  %d emissive  %s  "
              "AO %.0f%%  %.2f x %.2f x %.2f m  ground %+.3f"
              % ("ok  " if ok else "FAIL", name, a["tris"], budget, a["surfaces"],
                 a["emissive"],
                 ("COLOR_0+UV" if a["uvs"] else "NO UV") if a["colours"]
                 else "NO COLOUR",
                 mean_occ * 100.0, a["size"][0], a["size"][1], a["size"][2],
                 a["ground"]))

    total = sum(r[1]["tris"] for r in rows)
    print("\n  %d props, %d triangles total" % (len(rows), total))
    if bad:
        print("  %d PROP(S) FAILED THEIR BUDGET OR CONTRACT" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
