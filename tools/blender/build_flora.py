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
import bpy, sys, os, math, struct, json

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mathutils import Matrix, Vector
from _bl import script_args
import _organic as og

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
PALETTE = [
    ("bone",     "b3a892", None,     0.0),   # pale ribbed arch material
    ("husk",     "26362f", None,     0.0),   # dark green-black tendril skin
    ("flesh",    "7c4fb0", None,     0.0),   # purple lobed growth
    ("stone",    "2b3036", None,     0.0),   # rock
    ("glow_t",   "0d3b38", "2ff0d0", 6.0),   # teal bioluminescence
    ("glow_p",   "2a1140", "b061ff", 5.0),   # violet bioluminescence
    ("glow_a",   "3a1c07", "ff9a3c", 5.0),   # amber ocelli
]
BONE, HUSK, FLESH, STONE, GLOW_T, GLOW_P, GLOW_A = range(7)


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
    """Accumulates triangles + per-triangle material index."""

    def __init__(self):
        self.v, self.f, self.m = [], [], []

    def add(self, verts, tris, mat, M=None):
        off = len(self.v)
        if M is None:
            self.v.extend(tuple(p) for p in verts)
        else:
            self.v.extend(tuple(M @ Vector(p)) for p in verts)
        for t in tris:
            self.f.append(tuple(off + i for i in t))
            self.m.append(mat)

    def tube(self, mat, points, radii, sides=7, **kw):
        v, t = og.tube(points, radii, sides, **kw)
        self.add(v, t, mat)

    def orb(self, mat, at, r, segs=8, rings=5, **kw):
        v, t = og.sphere(r, segs, rings, **kw)
        self.add(v, t, mat, xform(at))

    def shard(self, mat, at, r, h, sides=6, rot=(0, 0, 0), **kw):
        v, t = og.shard(r, h, sides, **kw)
        self.add(v, t, mat, xform(at, rot))

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


def make_object(name, mb, mats):
    me = bpy.data.meshes.new(name + "_mesh")
    me.from_pydata(mb.v, [], mb.f)
    me.update()
    for m in mats:
        me.materials.append(m)
    for i, mi in enumerate(mb.m):
        me.polygons[i].material_index = mi
    # Smooth shading everywhere: these are grown things, and flat-shaded tubes
    # at seven sides read as pipes.
    for poly in me.polygons:
        poly.use_smooth = True
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
    mb = MB()
    span, rise = 2.9, 4.1

    # Three struts, spread WIDE and ribbed hard. The first pass sat them 0.55 m
    # apart with a 0.10 ridge and the render came back as one smooth grey tube:
    # at RTS distance the struts have to be separated by more than their own
    # diameter before the gaps between them read as fenestration at all.
    struts = []
    for k, (dy, bow, rad) in enumerate([(-1.05, -0.35, 0.155),
                                        (0.05, 0.12, 0.185),
                                        (1.12, 0.38, 0.140)]):
        pts = og.arc((-span, dy, 0.0), (span * 0.92, dy * 0.7, 0.0),
                     rise * (1.0 - 0.09 * k), 11, bow=bow)
        radii = [rad * (0.55 + 0.9 * math.sin(i / 10.0 * math.pi) ** 0.5) + 0.05
                 for i in range(11)]
        radii[0] = radii[-1] = rad * 1.7           # splayed feet
        mb.tube(BONE, pts, radii, 7, ridge=0.26, seed=k * 3.0)
        struts.append(pts)

    # Cross ribs. The gaps between them are the fenestration — at this budget a
    # real hole would cost more triangles than the whole prop has.
    for i in range(1, 11, 2):
        for a, b in ((0, 1), (1, 2)):
            p, q = struts[a][i], struts[b][i]
            mb.tube(BONE, [p, q], [0.070, 0.070], 5, caps=True, seed=i)

    # Ocelli: the glowing eye-spots. Set ON the outer struts rather than
    # floating in the middle of the arch, where the ribs hid them completely.
    for i, mat, r in ((3, GLOW_A, 0.22), (5, GLOW_T, 0.26), (7, GLOW_A, 0.19)):
        for side in (0, 2):
            p = struts[side][i]
            out = 0.16 if side == 2 else -0.16
            mb.orb(mat, (p[0], p[1] + out, p[2]), r, 8, 5, lumps=0.12, seed=i + side)
    for i in (2, 9):
        p = struts[1][i]
        mb.orb(GLOW_T, (p[0], p[1], p[2] + 0.20), 0.15, 6, 4, seed=i)

    # Root flare where it meets the ground, so it grows out rather than
    # balancing on two sticks.
    for pts in (struts[0], struts[2]):
        for end in (pts[0], pts[-1]):
            mb.orb(BONE, (end[0], end[1], 0.14), 0.38, 7, 4,
                   squash=0.42, lumps=0.22, seed=end[0])
    return mb


# =============================================================================
# TENDRIL — the snaking glowing vine that ties the whole image together
# =============================================================================
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
    mb.tube(HUSK, stem, [0.17, 0.13, 0.10], 6, ridge=0.08)
    tips = []
    for k in range(5):
        a = -0.9 + k * 0.45
        lean = 0.62 + 0.10 * (k % 3)
        top = (math.sin(a) * lean, math.cos(a) * lean * 0.55, 1.22 + 0.16 * (k % 2))
        mid = og.lerp3(stem[-1], top, 0.55)
        mid = (mid[0] * 0.75, mid[1] * 0.75, mid[2] + 0.10)
        mb.tube(HUSK, [stem[-1], mid, top], [0.10, 0.07, 0.035], 5, seed=k)
        tips.append(top)
    for k, t in enumerate(tips):
        mb.orb(GLOW_T if k % 2 == 0 else GLOW_P, t, 0.10, 6, 4, lumps=0.2, seed=k)
    mb.orb(HUSK, (0.0, 0.0, 0.07), 0.30, 7, 4, squash=0.4, lumps=0.25)
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
        mb.tube(HUSK, [(x * 0.35, y * 0.35, 0.0), (x * 0.8, y * 0.8, z * 0.55),
                       (x, y, z - r * 0.5)], [0.055, 0.042, 0.030], 5, seed=x)
        mb.orb(mat, (x, y, z), r, 7, 5, lumps=0.14, seed=y)
    mb.orb(HUSK, (0.0, 0.0, 0.05), 0.34, 7, 4, squash=0.30, lumps=0.30)
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
    mb = MB()
    mb.shard(STONE, (0.0, 0.0, 0.0), 0.62, 2.35, 7, taper=0.16, lean=0.22, seed=1.0)
    mb.shard(STONE, (0.46, 0.20, 0.0), 0.34, 1.25, 6, taper=0.20, lean=-0.14, seed=4.0)
    mb.shard(STONE, (-0.38, -0.26, 0.0), 0.27, 0.86, 5, taper=0.25, lean=0.10, seed=9.0)
    # One vein of light in the rock, so it belongs to this map and not another.
    mb.tube(GLOW_T, [(-0.10, 0.18, 0.12), (0.06, 0.22, 0.84), (0.18, 0.12, 1.42)],
            [0.045, 0.032, 0.020], 5)
    return mb


PROPS = [
    ("flora_arch", build_arch, 1400),
    ("flora_tendril", build_tendril, 620),
    ("flora_coral", build_coral, 520),
    ("flora_pods", build_pods, 420),
    ("flora_brain", build_brain, 900),
    ("rock_spire", build_spire, 200),
]


# --- export + audit ---------------------------------------------------------
def export_glb(path):
    bpy.ops.export_scene.gltf(
        filepath=path, export_format='GLB', export_apply=True,
        export_yup=True, export_materials='EXPORT', use_selection=False)


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
        "tris": tris, "budget": budget, "emissive": emissive,
        "ground": lo[1], "size": tuple(hi[k] - lo[k] for k in range(3)),
        "surfaces": len(meshes[0]["primitives"]),
    }


def main():
    print("SENTINEL — biodome dressing\n")
    rows, bad = [], 0
    for name, fn, budget in PROPS:
        mats = new_scene()
        mb = fn(mats).ground()
        make_object(name, mb, mats)
        path = os.path.join(OUT, name + ".glb")
        export_glb(path)
        a = audit(path, budget)
        ok = a["tris"] <= budget and a["emissive"] > 0 and abs(a["ground"]) < 0.02
        bad += 0 if ok else 1
        rows.append((name, a, ok))
        print("  %s  %-14s %5d / %-5d tris  %d surf  %d emissive  "
              "%.2f x %.2f x %.2f m  ground %+.3f"
              % ("ok  " if ok else "FAIL", name, a["tris"], budget, a["surfaces"],
                 a["emissive"], a["size"][0], a["size"][1], a["size"][2], a["ground"]))

    total = sum(r[1]["tris"] for r in rows)
    print("\n  %d props, %d triangles total" % (len(rows), total))
    if bad:
        print("  %d PROP(S) FAILED THEIR BUDGET OR CONTRACT" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
