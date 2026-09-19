"""SENTINEL — procedural buildable structures (turret, radar, bulwark).

Three mobile structures, one .glb each, built from explicit triangle lists so
the triangle count is known exactly before export and can be asserted against
the exported glTF afterwards.

    ~/.cache/blender-venv/bin/python tools/blender/build_structures.py [out_dir]

Conventions (project asset pass):
  * metres, Z-up in Blender; the glTF exporter converts to Y-up for Godot
  * origin at the ground contact point (lowest geometry sits at z = 0)
  * solid colours + emission only, no UVs, no textures
  * fully deterministic: no random calls anywhere, no timestamps

Design notes
  These are MOBILE structures — they travel with the module rather than
  rooting down — so each carries visible locomotion:
    turret   tracked bogies + folded rear outrigger jacks
    radar    sled skids + folded side stabiliser legs
    bulwark  heavy skid shoes + corner rollers + folded anchor spikes

Node contract for Godot:
    turret.glb    Turret  > turret_base, turret_head (> turret_muzzle_l/_r)
    radar.glb     Radar   > radar_base, radar_dish
    bulwark.glb   Bulwark > bulwark_body
  'turret_head' and 'radar_dish' are separate child nodes with their pivots on
  the rotation axis, so Godot rotates the node directly with no offset fudging.
"""
import bpy, sys, os, math, struct, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _ao import default_sky, load_sky, sky_light_scene   # noqa: E402
from mathutils import Matrix, Vector

from _bl import script_args  # noqa: F401  (kept so both front ends work)

argv = script_args()
OUT = argv[0] if argv else "models"
OUT = os.path.abspath(OUT)
os.makedirs(OUT, exist_ok=True)

TRI_BUDGET = 900            # hard limit per structure (sum of its meshes)

TAU = math.tau


# --- palette ----------------------------------------------------------------
# The hexes in the brief are sRGB. glTF baseColorFactor / emissiveFactor are
# LINEAR, so convert; feeding the raw sRGB bytes in as linear renders roughly
# two stops too dark.
def _s2l(b):
    c = b / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


# tools/blender/build_chassis.py feeds the raw sRGB bytes straight in as linear,
# which renders the palette roughly two stops dark. Set this False to match that
# older file if the whole asset pass needs to agree before it gets fixed.
SRGB_TO_LINEAR = True


def hexcol(h):
    f = _s2l if SRGB_TO_LINEAR else (lambda b: b / 255.0)
    return tuple(f(int(h[i:i + 2], 16)) for i in (0, 2, 4)) + (1.0,)


HULL_HEX, PLATE_HEX, ACCENT_HEX = "12303a", "16222c", "4fe3c1"
HULL, PLATE, ACCENT = 0, 1, 2            # material slot indices


def set_in(bsdf, name, value):
    if name in bsdf.inputs:
        bsdf.inputs[name].default_value = value


def make_materials():
    """Three shared slots, same index order in every mesh in the file."""
    mats = []
    for name, hexv, rough, metal, emit in (
        ("sentinel_hull",   HULL_HEX,   0.62, 0.15, False),
        ("sentinel_plate",  PLATE_HEX,  0.46, 0.30, False),
        ("sentinel_accent", ACCENT_HEX, 0.30, 0.00, True),
    ):
        m = bpy.data.materials.new(name)
        m.use_nodes = True
        bsdf = next(n for n in m.node_tree.nodes if n.type == 'BSDF_PRINCIPLED')
        col = hexcol(hexv)
        set_in(bsdf, "Base Color", col)
        set_in(bsdf, "Roughness", rough)
        set_in(bsdf, "Metallic", metal)
        if emit:
            set_in(bsdf, "Emission Color", col)
            set_in(bsdf, "Emission Strength", 1.0)
        else:
            set_in(bsdf, "Emission Strength", 0.0)
        mats.append(m)
    return mats


# --- primitive generators (pure triangles, outward winding) ------------------
def g_box(sx, sy, sz):
    hx, hy, hz = sx * 0.5, sy * 0.5, sz * 0.5
    v = [(-hx, -hy, -hz), (hx, -hy, -hz), (hx, hy, -hz), (-hx, hy, -hz),
         (-hx, -hy, hz), (hx, -hy, hz), (hx, hy, hz), (-hx, hy, hz)]
    quads = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4),
             (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
    t = []
    for a, b, c, d in quads:
        t += [(a, b, c), (a, c, d)]
    return v, t                                    # 12 tris


def _ring_faces(n):
    """Caps + sides for two n-vertex rings (bottom 0..n-1, top n..2n-1)."""
    t = []
    for i in range(1, n - 1):                      # bottom cap, -Z
        t.append((0, i + 1, i))
    for i in range(1, n - 1):                      # top cap, +Z
        t.append((n, n + i, n + i + 1))
    for i in range(n):                             # sides
        j = (i + 1) % n
        t += [(i, j, n + j), (i, n + j, n + i)]
    return t                                       # 4n - 4 tris


def g_extrude(profile, depth):
    """CCW profile in XY, extruded +/- depth/2 along Z."""
    n = len(profile)
    hz = depth * 0.5
    v = [(x, y, -hz) for (x, y) in profile] + [(x, y, hz) for (x, y) in profile]
    return v, _ring_faces(n)                       # 4n - 4 tris


def g_cone(n, r1, r2, h, phase=0.0):
    """n-sided prism / truncated cone about local Z, centred on the origin."""
    hz = h * 0.5
    bot = [(r1 * math.cos(phase + i * TAU / n), r1 * math.sin(phase + i * TAU / n), -hz)
           for i in range(n)]
    top = [(r2 * math.cos(phase + i * TAU / n), r2 * math.sin(phase + i * TAU / n), hz)
           for i in range(n)]
    return bot + top, _ring_faces(n)               # 4n - 4 tris


def xform(loc=(0, 0, 0), rot=(0, 0, 0)):
    return (Matrix.Translation(Vector(loc))
            @ Matrix.Rotation(rot[2], 4, 'Z')
            @ Matrix.Rotation(rot[1], 4, 'Y')
            @ Matrix.Rotation(rot[0], 4, 'X'))


RX90 = (math.pi * 0.5, 0.0, 0.0)     # stands an XY profile up into XZ
RY90 = (0.0, math.pi * 0.5, 0.0)     # local +Z -> design-forward (barrels)

# Everything below is authored with "forward" = Blender +X, because that keeps
# the profile lists readable as (forward, up) pairs. Godot's forward is -Z, and
# the glTF exporter maps Blender (x, y, z) -> glTF (x, z, -y), so Blender +Y is
# the axis that lands on glTF -Z. ORIENT is a quarter turn that takes the
# authored +X forward onto +Y, baked into the vertices rather than left on a
# node transform so the exported nodes keep identity rotations.
ORIENT = Matrix.Rotation(math.pi * 0.5, 4, 'Z')


class MB:
    """Accumulates triangles + per-triangle material index."""

    def __init__(self):
        self.v, self.f, self.m = [], [], []

    def _emit(self, verts, tris, mat, M):
        off = len(self.v)
        M = ORIENT @ M
        self.v.extend(tuple(M @ Vector(p)) for p in verts)
        for t in tris:
            self.f.append(tuple(off + i for i in t))
            self.m.append(mat)

    def box(self, mat, size, loc=(0, 0, 0), rot=(0, 0, 0)):
        v, t = g_box(*size)
        self._emit(v, t, mat, xform(loc, rot))

    def ext(self, mat, profile, depth, loc=(0, 0, 0), rot=RX90):
        """Profile given as (forward, up) pairs; RX90 stands it up Z-up."""
        v, t = g_extrude(profile, depth)
        self._emit(v, t, mat, xform(loc, rot))

    def cone(self, mat, n, r1, r2, h, loc=(0, 0, 0), rot=(0, 0, 0), phase=0.0):
        v, t = g_cone(n, r1, r2, h, phase)
        self._emit(v, t, mat, xform(loc, rot))

    @property
    def tris(self):
        return len(self.f)


def make_object(name, mb, mats, parent=None, loc=(0, 0, 0)):
    me = bpy.data.meshes.new(name + "_mesh")
    me.from_pydata(mb.v, [], mb.f)
    me.update()
    for m in mats:
        me.materials.append(m)
    for i, mi in enumerate(mb.m):
        me.polygons[i].material_index = mi
    ob = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(ob)
    ob.location = loc
    if parent is not None:
        ob.parent = parent
    return ob


def empty(name, parent, loc):
    e = bpy.data.objects.new(name, None)
    e.empty_display_type = 'ARROWS'
    e.empty_display_size = 0.12
    e.location = ORIENT @ Vector(loc)
    bpy.context.collection.objects.link(e)
    e.parent = parent
    return e


def new_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    return make_materials()


def root_empty(name):
    r = bpy.data.objects.new(name, None)
    r.empty_display_type = 'PLAIN_AXES'
    bpy.context.collection.objects.link(r)
    return r


# =============================================================================
# TURRET  —  tracked weapon post, ~1.40 m base, rotating head, twin barrels
# =============================================================================
HEAD_PIVOT_Z = 0.82


def build_turret(mats):
    root = root_empty("Turret")

    b = MB()
    # --- locomotion: two tracked bogies -------------------------------------
    track = [(-0.60, 0.00), (0.60, 0.00), (0.70, 0.24),
             (0.60, 0.44), (-0.60, 0.44), (-0.70, 0.24)]
    for s in (1, -1):
        b.ext(PLATE, track, 0.22, loc=(0.0, 0.50 * s, 0.0))
        for x in (0.40, -0.40):                       # sprocket + idler
            b.cone(PLATE, 8, 0.13, 0.13, 0.05, loc=(x, 0.63 * s, 0.24), rot=RX90)
        b.cone(PLATE, 6, 0.075, 0.075, 0.05, loc=(0.0, 0.63 * s, 0.24), rot=RX90)
        b.box(HULL, (1.44, 0.28, 0.06), loc=(0.0, 0.52 * s, 0.50))   # fender

    # --- hull ----------------------------------------------------------------
    b.box(HULL, (1.06, 0.86, 0.38), loc=(0.0, 0.0, 0.43))
    b.ext(HULL, [(0.53, 0.24), (0.78, 0.24), (0.53, 0.62)], 0.70)     # glacis
    b.box(PLATE, (0.22, 0.62, 0.30), loc=(-0.62, 0.0, 0.42))          # rear bay
    b.box(HULL, (0.94, 0.78, 0.10), loc=(0.0, 0.0, 0.67))             # deck

    for s in (1, -1):
        for x in (0.24, -0.24):
            b.box(PLATE, (0.44, 0.06, 0.24), loc=(x, 0.45 * s, 0.44))
        for x in (0.46, -0.46):
            b.box(PLATE, (0.16, 0.16, 0.40), loc=(x, 0.36 * s, 0.44))
        b.box(ACCENT, (0.34, 0.03, 0.04), loc=(0.05, 0.455 * s, 0.56))
        # folded rear outrigger jack (deploys when it plants to fire)
        b.box(PLATE, (0.10, 0.10, 0.36), loc=(-0.58, 0.34 * s, 0.34), rot=(0, 0.5, 0))
        b.box(PLATE, (0.14, 0.14, 0.05), loc=(-0.645, 0.34 * s, 0.17))

    for x in (-0.56, -0.62, -0.68):                                   # rear vents
        b.box(PLATE, (0.04, 0.50, 0.05), loc=(x, 0.0, 0.58))
    b.box(PLATE, (0.20, 0.16, 0.16), loc=(-0.38, 0.0, 0.70))          # ammo conduit
    b.cone(PLATE, 10, 0.36, 0.33, 0.10, loc=(0.0, 0.0, 0.77))         # turret ring

    base = make_object("turret_base", b, mats, root)

    # --- rotating head (pivot on the ring axis, local z = 0 at the ring top) --
    h = MB()
    h.cone(PLATE, 8, 0.26, 0.26, 0.08, loc=(0.0, 0.0, -0.03))         # pintle
    h.box(HULL, (0.58, 0.58, 0.30), loc=(0.0, 0.0, 0.17))
    h.box(PLATE, (0.14, 0.46, 0.30), loc=(0.32, 0.0, 0.17))           # mantlet
    h.box(PLATE, (0.28, 0.48, 0.26), loc=(-0.38, 0.0, 0.16))          # bustle
    h.box(HULL, (0.30, 0.34, 0.10), loc=(-0.04, 0.0, 0.37))           # riser
    for s in (1, -1):
        h.box(PLATE, (0.30, 0.06, 0.22), loc=(0.12, 0.31 * s, 0.17))  # cheek
        h.cone(PLATE, 8, 0.05, 0.05, 0.52, loc=(0.58, 0.115 * s, 0.17), rot=RY90)
        h.box(PLATE, (0.20, 0.12, 0.12), loc=(0.44, 0.115 * s, 0.17))  # shroud
        h.box(PLATE, (0.10, 0.14, 0.14), loc=(0.80, 0.115 * s, 0.17))  # brake
        h.box(PLATE, (0.12, 0.10, 0.14), loc=(-0.10, 0.32 * s, 0.30))  # hardpoint
    for z in (0.31, 0.36, 0.41):
        h.box(PLATE, (0.22, 0.42, 0.03), loc=(-0.38, 0.0, z))         # bustle fins
    h.box(PLATE, (0.14, 0.20, 0.12), loc=(0.18, 0.0, 0.38))           # optics
    h.box(ACCENT, (0.03, 0.14, 0.07), loc=(0.26, 0.0, 0.38))          # lens

    head = make_object("turret_head", h, mats, root, loc=(0.0, 0.0, HEAD_PIVOT_Z))
    empty("turret_muzzle_l", head, (0.86, 0.115, 0.17))
    empty("turret_muzzle_r", head, (0.86, -0.115, 0.17))

    return root, {"turret_base": base.data, "turret_head": head.data}, \
        ["Turret", "turret_base", "turret_head", "turret_muzzle_l", "turret_muzzle_r"]


# =============================================================================
# RADAR  —  skid-mounted mast, ~1.24 m base, ~2.4 m tall, spinning dish
# =============================================================================
DISH_PIVOT_Z = 1.81
DISH_TILT = 0.55                     # radians, dish axis tipped toward +X


def build_radar(mats):
    root = root_empty("Radar")

    b = MB()
    # --- locomotion: sled skids + folded stabiliser legs ---------------------
    skid = [(-0.52, 0.00), (0.52, 0.00), (0.62, 0.12),
            (0.60, 0.20), (-0.60, 0.20), (-0.62, 0.12)]
    for s in (1, -1):
        b.ext(PLATE, skid, 0.16, loc=(0.0, 0.42 * s, 0.0))
        for x in (0.30, -0.30):
            b.box(PLATE, (0.09, 0.09, 0.30), loc=(x, 0.36 * s, 0.30),
                  rot=(0, 0.35 if x > 0 else -0.35, 0))
            b.box(PLATE, (0.30, 0.05, 0.22), loc=(x * 0.67, 0.355 * s, 0.47))
        b.box(PLATE, (0.05, 0.50, 0.22), loc=(0.44 * s, 0.0, 0.47))
        b.box(PLATE, (0.08, 0.08, 0.36), loc=(0.0, 0.40 * s, 0.44), rot=(-0.4 * s, 0, 0))
        b.box(PLATE, (0.14, 0.16, 0.05), loc=(0.0, 0.54 * s, 0.24))
    for x in (0.34, -0.34):
        b.box(PLATE, (0.10, 0.94, 0.09), loc=(x, 0.0, 0.15))          # skid brace

    # --- hull ---------------------------------------------------------------
    b.box(HULL, (0.84, 0.68, 0.34), loc=(0.0, 0.0, 0.47))
    b.box(HULL, (0.72, 0.60, 0.08), loc=(0.0, 0.0, 0.68))
    b.box(PLATE, (0.26, 0.40, 0.20), loc=(-0.26, 0.0, 0.82))          # processor
    for s in (1, -1):
        b.box(PLATE, (0.20, 0.04, 0.05), loc=(0.22, 0.16 * s, 0.74))  # vents
    b.box(ACCENT, (0.16, 0.16, 0.06), loc=(0.24, 0.0, 0.75))          # core glow

    # --- mast ---------------------------------------------------------------
    b.cone(PLATE, 8, 0.17, 0.15, 0.12, loc=(0.0, 0.0, 0.70))          # base collar
    b.cone(HULL, 6, 0.115, 0.065, 1.06, loc=(0.0, 0.0, 1.19))         # 0.66 -> 1.72
    for s in (1, -1):
        b.box(PLATE, (0.05, 0.05, 0.40), loc=(0.16 * s, 0.0, 0.95), rot=(0, -0.35 * s, 0))
        b.box(PLATE, (0.05, 0.05, 0.40), loc=(0.0, 0.16 * s, 0.95), rot=(0.35 * s, 0, 0))
    b.box(PLATE, (0.05, 0.05, 1.00), loc=(0.13, 0.0, 1.20))           # cable run
    b.box(ACCENT, (0.06, 0.06, 0.06), loc=(-0.12, 0.0, 1.60))         # warning light
    b.box(PLATE, (0.30, 0.08, 0.08), loc=(0.0, 0.0, 1.68))            # yoke support
    b.box(HULL, (0.24, 0.24, 0.09), loc=(0.0, 0.0, 1.765))            # bearing plate

    base = make_object("radar_base", b, mats, root)

    # --- rotating scanner head (spins about local Z) ------------------------
    d = MB()
    d.cone(PLATE, 8, 0.15, 0.13, 0.06, loc=(0.0, 0.0, 0.03))          # bearing hub
    d.box(HULL, (0.30, 0.20, 0.12), loc=(0.0, 0.0, 0.11))             # rotor housing
    for s in (1, -1):
        d.box(PLATE, (0.05, 0.05, 0.22), loc=(0.13, 0.09 * s, 0.26))  # yoke arms
    d.cone(HULL, 12, 0.13, 0.34, 0.16, loc=(0.0, 0.0, 0.30), rot=(0, DISH_TILT, 0))
    for s in (1, 0, -1):
        d.box(PLATE, (0.03, 0.03, 0.26), loc=(0.06, 0.11 * s, 0.24), rot=(0, DISH_TILT, 0))
    d.box(PLATE, (0.04, 0.04, 0.30), loc=(0.115, 0.0, 0.49), rot=(0, DISH_TILT, 0))
    d.box(ACCENT, (0.07, 0.07, 0.07), loc=(0.157, 0.0, 0.556))        # feed horn
    d.box(HULL, (0.62, 0.07, 0.05), loc=(-0.28, 0.0, 0.14))           # scanner bar
    d.box(ACCENT, (0.44, 0.03, 0.02), loc=(-0.34, 0.0, 0.175))        # emitter strip
    d.box(PLATE, (0.12, 0.14, 0.12), loc=(-0.54, 0.0, 0.14))          # counterweight

    dish = make_object("radar_dish", d, mats, root, loc=(0.0, 0.0, DISH_PIVOT_Z))

    return root, {"radar_base": base.data, "radar_dish": dish.data}, \
        ["Radar", "radar_base", "radar_dish"]


# =============================================================================
# BULWARK  —  ~1.55 m squat armoured blocker, no moving parts, one mesh
# =============================================================================
def build_bulwark(mats):
    root = root_empty("Bulwark")
    b = MB()

    # --- locomotion: heavy skid shoes + corner rollers + folded anchors ------
    shoe = [(-0.54, 0.00), (0.54, 0.00), (0.62, 0.10),
            (0.58, 0.20), (-0.58, 0.20), (-0.62, 0.10)]
    for s in (1, -1):
        b.ext(PLATE, shoe, 0.24, loc=(0.0, 0.44 * s, 0.0))
        for x in (0.34, -0.34):
            b.cone(PLATE, 6, 0.10, 0.10, 0.06, loc=(x, 0.58 * s, 0.16), rot=RX90)
            b.box(PLATE, (0.16, 0.10, 0.18), loc=(x, 0.58 * s, 0.22))
            # folded anchor spike, stowed against the flank
            b.box(PLATE, (0.08, 0.08, 0.30), loc=(x * 1.45, 0.30 * s, 0.28),
                  rot=(0, 0.7 * (1 if x > 0 else -1), 0))
            d = 1.0 if x > 0 else -1.0
            b.ext(PLATE, [(0.0, 0.0), (0.10 * d, 0.05), (0.0, 0.10)][::int(d)], 0.08,
                  loc=(x * 1.45 + 0.13 * d, 0.30 * s, 0.10))

    # --- armour -------------------------------------------------------------
    b.box(HULL, (1.14, 0.94, 0.44), loc=(0.0, 0.0, 0.44))
    b.ext(HULL, [(0.54, 0.22), (0.70, 0.34), (0.70, 0.56), (0.54, 0.70)], 0.80)
    b.ext(HULL, [(-0.54, 0.22), (-0.54, 0.70), (-0.70, 0.56), (-0.70, 0.34)], 0.80)
    for x in (-0.42, -0.14, 0.14, 0.42):
        b.box(PLATE, (0.26, 0.88, 0.08), loc=(x, 0.0, 0.70))          # top bank
    for s in (1, -1):
        for y in (0.28, 0.0, -0.28):
            b.box(PLATE, (0.06, 0.24, 0.40), loc=(0.735 * s, y, 0.46))
        for x in (-0.45, -0.15, 0.15, 0.45):
            b.box(PLATE, (0.26, 0.06, 0.34), loc=(x, 0.49 * s, 0.44))
        for x in (0.52, -0.52):
            b.box(PLATE, (0.14, 0.14, 0.52), loc=(x, 0.43 * s, 0.46))  # buttress
            b.box(PLATE, (0.07, 0.07, 0.07), loc=(x, 0.43 * s, 0.755))  # bolt boss
        for x in (0.30, -0.30):
            b.box(PLATE, (0.07, 0.07, 0.07), loc=(x, 0.50 * s, 0.775))
        b.box(HULL, (0.10, 1.00, 0.10), loc=(0.50 * s, 0.0, 0.79))     # brow ridge
        b.box(PLATE, (0.12, 0.10, 0.10), loc=(0.68 * s, 0.0, 0.30))    # tow lug
    b.box(ACCENT, (0.05, 0.10, 0.05), loc=(0.75, 0.0, 0.60))           # status light

    body = make_object("bulwark_body", b, mats, root)
    return root, {"bulwark_body": body.data}, ["Bulwark", "bulwark_body"]


# =============================================================================
# export + verification
# =============================================================================
def export_glb(path):
    # THE SKY, BAKED IN, JUST BEFORE THE FILE IS WRITTEN. These models carried
    # no vertex colour at all until now — they were lit entirely by the runtime
    # rig while the landscape under them had a whole-map light bake.
    sky_light_scene(load_sky(default_sky()))
    kwargs = dict(
        filepath=path,
        export_format='GLB',
        export_apply=True,
        export_yup=True,
        export_materials='EXPORT',
        use_selection=False,
    )
    # export_vertex_color='ACTIVE' forces COLOR_0 out even though no material
    # node reads it. Without it the exporter drops the bake entirely, because
    # the default only emits vertex colours a shader graph actually uses and
    # these materials deliberately do not — Godot applies COLOR_0 itself.
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


def node_matrix(nd):
    if "matrix" in nd:
        m = nd["matrix"]
        return Matrix([[m[0], m[4], m[8], m[12]],
                       [m[1], m[5], m[9], m[13]],
                       [m[2], m[6], m[10], m[14]],
                       [m[3], m[7], m[11], m[15]]])
    M = Matrix.Identity(4)
    if "translation" in nd:
        M = M @ Matrix.Translation(Vector(nd["translation"]))
    if "rotation" in nd:
        x, y, z, w = nd["rotation"]
        M = M @ _quat(x, y, z, w)
    if "scale" in nd:
        sx, sy, sz = nd["scale"]
        M = M @ Matrix.Diagonal(Vector((sx, sy, sz, 1.0)))
    return M


def _quat(x, y, z, w):
    from mathutils import Quaternion
    return Quaternion((w, x, y, z)).to_matrix().to_4x4()


def audit(path, promised_nodes, budget):
    doc = read_glb(path)
    nodes = doc.get("nodes", [])
    names = [nd.get("name", "") for nd in nodes]

    # triangles per mesh, from the index accessors the exporter actually wrote
    mesh_tris = {}
    for mi, mesh in enumerate(doc.get("meshes", [])):
        tot = 0
        for prim in mesh["primitives"]:
            assert prim.get("mode", 4) == 4, "non-triangle primitive mode"
            if "indices" in prim:
                tot += doc["accessors"][prim["indices"]]["count"] // 3
            else:
                tot += doc["accessors"][prim["attributes"]["POSITION"]]["count"] // 3
        mesh_tris[mi] = tot

    # world AABB: walk the hierarchy, transform each POSITION accessor's min/max
    lo = [float("inf")] * 3
    hi = [float("-inf")] * 3
    per_node_box = {}

    def walk(idx, parent):
        nd = nodes[idx]
        M = parent @ node_matrix(nd)
        if "mesh" in nd:
            nlo = [float("inf")] * 3
            nhi = [float("-inf")] * 3
            for prim in doc["meshes"][nd["mesh"]]["primitives"]:
                acc = doc["accessors"][prim["attributes"]["POSITION"]]
                mn, mx = acc["min"], acc["max"]
                for cx in (mn[0], mx[0]):
                    for cy in (mn[1], mx[1]):
                        for cz in (mn[2], mx[2]):
                            p = M @ Vector((cx, cy, cz))
                            for k in range(3):
                                lo[k] = min(lo[k], p[k])
                                hi[k] = max(hi[k], p[k])
                                nlo[k] = min(nlo[k], p[k])
                                nhi[k] = max(nhi[k], p[k])
            per_node_box[nd.get("name", "?")] = (nlo, nhi)
        for c in nd.get("children", []):
            walk(c, M)

    for sc in doc.get("scenes", []):
        for r in sc.get("nodes", []):
            walk(r, Matrix.Identity(4))

    label = os.path.basename(path)
    print("PY: --- %s ---" % label)
    print("PY: %s nodes: %s" % (label, ", ".join(n for n in names if n)))

    missing = [n for n in promised_nodes if n not in names]
    if missing:
        raise SystemExit("FAIL %s: promised nodes missing from glb: %s" % (label, missing))
    print("PY: %s node contract OK (%d/%d promised nodes present)"
          % (label, len(promised_nodes), len(promised_nodes)))

    total = 0
    for nd in nodes:
        if "mesh" in nd:
            t = mesh_tris[nd["mesh"]]
            total += t
            print("PY: %s mesh '%s' triangles = %d" % (label, nd.get("name", "?"), t))
    print("PY: %s TOTAL triangles = %d / budget %d" % (label, total, budget))
    if total > budget:
        raise SystemExit("FAIL %s: %d tris over budget %d" % (label, total, budget))

    # glTF is Y-up: x = width(lateral), y = height, z = depth(forward)
    size = [hi[k] - lo[k] for k in range(3)]
    print("PY: %s bbox min (%.3f, %.3f, %.3f) max (%.3f, %.3f, %.3f) metres"
          % (label, lo[0], lo[1], lo[2], hi[0], hi[1], hi[2]))
    print("PY: %s size X=%.3f Y(height)=%.3f Z=%.3f metres" % (label, size[0], size[1], size[2]))

    if abs(lo[1]) > 1e-4:
        raise SystemExit("FAIL %s: ground contact not at 0 (min Y = %.5f)" % (label, lo[1]))
    print("PY: %s ground contact OK (min Y = %.6f)" % (label, lo[1]))

    cx = (lo[0] + hi[0]) * 0.5
    cz = (lo[2] + hi[2]) * 0.5
    print("PY: %s XZ centre offset = (%.4f, %.4f) metres" % (label, cx, cz))

    emissive = [m.get("name", "?") for m in doc.get("materials", [])
                if any(v > 0.0 for v in m.get("emissiveFactor", [0, 0, 0]))]
    print("PY: %s materials = %s ; emissive = %s"
          % (label, [m.get("name") for m in doc.get("materials", [])], emissive))
    if not emissive:
        raise SystemExit("FAIL %s: no emissive material survived export" % label)

    if doc.get("images") or doc.get("textures"):
        raise SystemExit("FAIL %s: textures present, this project has no texture pipeline" % label)
    print("PY: %s no textures/images in glb OK" % label)

    return total, size, per_node_box


def main():
    specs = [("turret", build_turret), ("radar", build_radar), ("bulwark", build_bulwark)]
    results = []
    for name, fn in specs:
        mats = new_scene()
        root, meshes, promised = fn(mats)
        predicted = {k: len(v.polygons) for k, v in meshes.items()}
        print("PY: %s built in blender, tris by mesh %s (sum %d)"
              % (name, predicted, sum(predicted.values())))
        path = os.path.join(OUT, name + ".glb")
        export_glb(path)
        print("PY: exported %s (%d bytes)" % (path, os.path.getsize(path)))
        total, size, boxes = audit(path, promised, TRI_BUDGET)
        for n, (lo, hi) in sorted(boxes.items()):
            print("PY: %s.glb node '%s' bbox size = (%.3f, %.3f, %.3f) m, "
                  "XZ centre offset = (%.3f, %.3f) m"
                  % (name, n, hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2],
                     (lo[0] + hi[0]) * 0.5, (lo[2] + hi[2]) * 0.5))
        results.append((name, total, size))

    print("PY: ===== summary =====")
    for name, total, size in results:
        print("PY: %-8s %4d tris   %.2f x %.2f x %.2f m (X, height, Z)"
              % (name, total, size[0], size[1], size[2]))
    print("PY: ALL CHECKS PASSED")


main()
