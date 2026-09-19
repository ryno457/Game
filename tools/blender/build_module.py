"""SENTINEL — the player MODULE, three growth forms, one .glb.

The module is the player's body and the thing they watch grow. The three forms
are the SAME machine at three stages of accretion, so the geometry is built
that way on purpose:

    * The CORE DRUM is byte-for-byte the same size in all three forms. It is
      the original crashed pod. It never scales.
    * Growth happens by bolting tiers of salvaged plate AROUND and ON TOP of
      that unchanged core. Form 1 adds an apron ring, form 2 adds a second,
      taller ring plus recessed vents. Mass spent is mass visibly lost.
    * The breach in form 0 is a genuinely missing outer armour panel, not a
      painted-on dent: the facet ring is built as eight separate plates and
      form 0 simply omits one, exposing the darker inner drum behind it.
      Form 1 rivets a salvage patch over it. Form 2 armours over the patch.

Everything is in metres, built Z-up (the glTF exporter converts to Y-up for
Godot). Each form's origin is its ground contact point, centred in XY, so all
three sit at the world origin and overlap in the file — a form is meant to be
pulled out of the glb one at a time, not viewed together.

Run:
    ~/.cache/blender-venv/bin/python tools/blender/build_module.py [out_dir]
"""
import bpy, bmesh, os, sys, math, struct, json, random
from mathutils import Matrix, Vector, Euler

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _ao import default_sky, load_sky, sky_light_scene   # noqa: E402
try:
    from _bl import script_args
except Exception:                                    # pragma: no cover
    def script_args():
        return sys.argv[1:]

TAU = math.tau
SEED = 20260914

argv = script_args()
# Defaults to models/, the directory the GAME loads from — the same default
# build_machines.py has. It used to default to build/models/, which is a
# scratch directory nothing reads, so a palette change here rebuilt happily,
# printed all its assertions green, and left the shipped module untouched.
OUT = argv[0] if argv else os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                        "..", "..", "models")
OUT = os.path.abspath(OUT)
os.makedirs(OUT, exist_ok=True)
GLB = os.path.join(OUT, "module_forms.glb")

# --------------------------------------------------------------- palette ----
# SENTINEL machine palette. Solid colours + emission only; no textures.
#
# The palette is given as sRGB hex — display values. Blender shader inputs and
# glTF baseColorFactor are both LINEAR, so feeding the hex bytes in raw makes
# every surface far too light (#12303a arrives looking like #4b7883). Convert
# once, here, and assert the round-trip at the end of the file.
# LIGHT GREY, matching build_machines.py. Kept in step by hand because these
# two files each carry their own copy; last pass only build_machines.py was
# changed and the player's own MODULE stayed dark teal while its drone and
# guard went grey — the one object on screen that most needs to be findable.
HULL_HEX, PLATE_HEX, ACCENT_HEX = "b9bdc2", "8e949b", "4fe3c1"


def srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def hex_linear(h):
    v = [int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)]
    return tuple(srgb_to_linear(c) for c in v) + (1.0,)


HULL, PLATE, ACCENT = hex_linear(HULL_HEX), hex_linear(PLATE_HEX), hex_linear(ACCENT_HEX)
M_HULL, M_PLATE, M_ACCENT = 0, 1, 2

# --------------------------------------------------------- form geometry ----
# All polar radii below are APOTHEM (flat-to-centre) distances, so a form whose
# outermost apothem is W has an axis-aligned bounding box of exactly 2W. The
# octagon is oriented with a flat facet facing +X (the prow).
NSIDE = 8
FACET_MARGIN = 0.022                      # radians of seam between armour plates

# Core drum — IDENTICAL in every form.
C_PAD_R, C_PAD_H = 0.62, 0.09
C_DRUM_R0, C_DRUM_R1 = 0.58, 0.86
C_DRUM_Z0, C_DRUM_Z1 = 0.09, 0.36
C_INNER_R = 0.86
C_INNER_Z0, C_INNER_Z1 = 0.34, 0.78
C_PANEL_R0, C_PANEL_R1 = 0.86, 1.10
C_PANEL_Z0, C_PANEL_Z1 = 0.34, 0.78
C_RIM_Z0, C_RIM_Z1 = 0.76, 0.84
C_DECK_R = 0.98
C_DECK_Z = 0.84                            # core deck surface
C_TOWER_R, C_TOWER_Z1 = 0.34, 1.08
C_CAP_R, C_CAP_Z1 = 0.30, 1.14
BREACH_FACET = 2                           # facet centred on +Y

# Tier 1 apron (forms 1 and 2).
T1_PAD_R, T1_PAD_H = 1.45, 0.10
T1_SKIRT_R0, T1_SKIRT_R1 = 1.20, 1.56
T1_SKIRT_Z0, T1_SKIRT_Z1 = 0.08, 0.90
T1_ARM_R0, T1_ARM_R1 = 1.56, 1.70
T1_ARM_Z0, T1_ARM_Z1 = 0.30, 0.92
T1_WALL_R = 1.10
T1_DECK_R0, T1_DECK_R1 = 1.10, 1.70
T1_DECK_Z0, T1_DECK_Z1 = 0.90, 0.98

# Tier 2 armour ring (form 2 only).
T2_PAD_R, T2_PAD_H = 2.10, 0.12
T2_SKIRT_R0, T2_SKIRT_R1 = 1.78, 2.20
T2_SKIRT_Z0, T2_SKIRT_Z1 = 0.10, 1.02
T2_ARM_R0, T2_ARM_R1 = 2.20, 2.40
T2_ARM_Z0, T2_ARM_Z1 = 0.34, 1.04
T2_VENT_Z0, T2_VENT_Z1 = 0.62, 0.78       # gap in the armour the vents sit in
T2_WALL_R = 1.72
T2_DECK_R0, T2_DECK_R1 = 1.72, 2.40
T2_DECK_Z0, T2_DECK_Z1 = 1.02, 1.10

# Per-form deck the six bays ring, and the target footprint.
FORM_SPEC = [
    dict(width=2.20, bay_r=0.80, bay_z=C_DECK_Z + 0.02),
    dict(width=3.40, bay_r=1.40, bay_z=T1_DECK_Z1 + 0.02),
    dict(width=4.80, bay_r=2.05, bay_z=T2_DECK_Z1 + 0.02),
]
BAYS = 6

# ------------------------------------------------------------ primitives ----
# Every primitive returns (verts, faces) with outward-facing winding. Faces are
# quads/ngons; the whole thing is triangulated once at the end.


def _apo(n):
    """vertex radius / apothem for a regular n-gon."""
    return 1.0 / math.cos(math.pi / n)


def mk_box(sx, sy, sz):
    hx, hy, hz = sx * 0.5, sy * 0.5, sz * 0.5
    v = [(-hx, -hy, -hz), (hx, -hy, -hz), (hx, hy, -hz), (-hx, hy, -hz),
         (-hx, -hy, hz), (hx, -hy, hz), (hx, hy, hz), (-hx, hy, hz)]
    f = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4),
         (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
    return v, f


def mk_prism(n, r0, r1, z0, z1, cap0=True, cap1=True):
    """n-gon frustum. r0/r1 are apothem radii at z0/z1. Flat facet faces +X."""
    k = _apo(n)
    v = []
    for r, z in ((r0, z0), (r1, z1)):
        for i in range(n):
            a = (i + 0.5) * TAU / n
            v.append((math.cos(a) * r * k, math.sin(a) * r * k, z))
    f = []
    for i in range(n):
        j = (i + 1) % n
        f.append((i, j, n + j, n + i))
    if cap0:
        f.append(tuple(range(n - 1, -1, -1)))
    if cap1:
        f.append(tuple(range(n, 2 * n)))
    return v, f


def mk_slab(a0, a1, r_in, r_out, z0, z1, ac=None):
    """One armour plate: a trapezoidal slab between two angles. Apothem radii.

    Corners lie on the facet PLANE (distance r from centre along the facet
    normal), not on the circumscribed circle — otherwise the seam margin walks
    the corners outboard and the whole form measures wider than it is.
    """
    if ac is None:
        ac = (a0 + a1) * 0.5

    def p(a, r, z):
        rr = r / math.cos(a - ac)
        return (math.cos(a) * rr, math.sin(a) * rr, z)

    v = [p(a0, r_in, z0), p(a1, r_in, z0), p(a1, r_out, z0), p(a0, r_out, z0),
         p(a0, r_in, z1), p(a1, r_in, z1), p(a1, r_out, z1), p(a0, r_out, z1)]
    f = [(0, 1, 2, 3), (4, 7, 6, 5), (3, 2, 6, 7),
         (1, 0, 4, 5), (2, 1, 5, 6), (0, 3, 7, 4)]
    return v, f


def facet_span(i, margin=FACET_MARGIN):
    """(start, end, centre) angles of facet i, inset by a seam margin."""
    c = i * TAU / NSIDE
    return (c - 0.5 * TAU / NSIDE + margin, c + 0.5 * TAU / NSIDE - margin, c)


def xf(loc=(0.0, 0.0, 0.0), rot=(0.0, 0.0, 0.0)):
    return Matrix.Translation(Vector(loc)) @ Euler(rot, 'XYZ').to_matrix().to_4x4()


def polar(r, a, z):
    return (math.cos(a) * r, math.sin(a) * r, z)


def bevel_vf(verts, faces, offset, segments=1):
    """Chamfer one primitive's edges. Hard-surface reads as chamfers, not radii."""
    bm = bmesh.new()
    bv = [bm.verts.new(v) for v in verts]
    bm.verts.ensure_lookup_table()
    for f in faces:
        try:
            bm.faces.new([bv[i] for i in f])
        except ValueError:
            pass
    bm.faces.ensure_lookup_table()
    bm.normal_update()
    geom = list(bm.verts) + list(bm.edges) + list(bm.faces)
    bmesh.ops.bevel(bm, geom=geom, offset=offset, offset_type='OFFSET',
                    segments=segments, profile=0.5, affect='EDGES',
                    clamp_overlap=True)
    bm.verts.ensure_lookup_table()
    bm.verts.index_update()
    bm.faces.ensure_lookup_table()
    out_v = [tuple(v.co) for v in bm.verts]
    out_f = [tuple(x.index for x in f.verts) for f in bm.faces]
    bm.free()
    return out_v, out_f


class Build:
    """Accumulates (verts, faces, material) parts, then bakes one mesh."""

    def __init__(self, name):
        self.name = name
        self.parts = []

    def add(self, vf, mat, bevel=0.0, m=None):
        verts, faces = vf
        if m is not None:
            verts = [tuple(m @ Vector(v)) for v in verts]
        if bevel > 0.0:
            verts, faces = bevel_vf(verts, faces, bevel)
        self.parts.append((verts, faces, mat))
        return self

    def bake(self, materials):
        bm = bmesh.new()
        for verts, faces, mat in self.parts:
            bv = [bm.verts.new(v) for v in verts]
            bm.verts.ensure_lookup_table()
            for f in faces:
                try:
                    nf = bm.faces.new([bv[i] for i in f])
                    nf.material_index = mat
                except ValueError:
                    pass
        bm.faces.ensure_lookup_table()
        bmesh.ops.triangulate(bm, faces=bm.faces[:])
        me = bpy.data.meshes.new(self.name + "_mesh")
        bm.to_mesh(me)
        ntri = len(bm.faces)
        bm.free()
        for mat in materials:
            me.materials.append(mat)
        me.update()
        ob = bpy.data.objects.new(self.name, me)
        bpy.context.collection.objects.link(ob)
        return ob, ntri


# ----------------------------------------------------------- sub-assemblies --

def add_hatch(b, ang, r, z):
    """Cargo hatch: raised frame, recessed inner panel, two emissive seams."""
    m = xf(polar(r, ang, z), (0, 0, ang))
    b.add(mk_box(0.46, 0.54, 0.07), M_HULL, 0.012, m @ Matrix.Translation((0, 0, 0.035)))
    b.add(mk_box(0.32, 0.40, 0.05), M_PLATE, 0.0, m @ Matrix.Translation((0, 0, 0.055)))
    for s in (-1, 1):
        b.add(mk_box(0.30, 0.030, 0.020), M_ACCENT, 0.0,
              m @ Matrix.Translation((0, s * 0.215, 0.072)))


def add_dock(b, ang, r, z):
    """Drone landing pad: recessed plate with four emissive corner marks."""
    m = xf(polar(r, ang, z), (0, 0, ang))
    b.add(mk_box(0.52, 0.52, 0.05), M_PLATE, 0.012, m @ Matrix.Translation((0, 0, 0.025)))
    for sx in (-1, 1):
        for sy in (-1, 1):
            b.add(mk_box(0.09, 0.09, 0.022), M_ACCENT, 0.0,
                  m @ Matrix.Translation((sx * 0.19, sy * 0.19, 0.058)))
    return polar(r, ang, z + 0.05)


def add_core_drum(b, patched):
    """The original pod. Identical in all three forms — this is the point."""
    for i in range(4):
        a = (i * 2 + 1) * TAU / 8.0
        b.add(mk_box(0.34, 0.26, C_PAD_H), M_PLATE, 0.018,
              xf(polar(C_PAD_R, a, C_PAD_H * 0.5), (0, 0, a)))
    b.add(mk_prism(NSIDE, C_DRUM_R0, C_DRUM_R1, C_DRUM_Z0, C_DRUM_Z1), M_PLATE)
    b.add(mk_prism(NSIDE, C_INNER_R, C_INNER_R, C_INNER_Z0, C_INNER_Z1), M_PLATE)

    for i in range(NSIDE):
        if i == BREACH_FACET and not patched:
            continue                       # the breach: a genuinely absent plate
        a0, a1, ac = facet_span(i)
        b.add(mk_slab(a0, a1, C_PANEL_R0, C_PANEL_R1, C_PANEL_Z0, C_PANEL_Z1, ac),
              M_HULL, 0.028)

    b.add(mk_prism(NSIDE, C_PANEL_R1, C_DECK_R, C_RIM_Z0, C_RIM_Z1, cap0=False,
                   cap1=False), M_HULL)
    b.add(mk_prism(NSIDE, C_DECK_R, C_DECK_R, C_RIM_Z1 - 0.04, C_DECK_Z), M_PLATE)
    b.add(mk_prism(NSIDE, C_TOWER_R, C_TOWER_R, C_DECK_Z, C_TOWER_Z1), M_PLATE)
    b.add(mk_prism(NSIDE, C_TOWER_R + 0.03, C_TOWER_R + 0.03, 0.92, 1.00), M_ACCENT)
    b.add(mk_prism(NSIDE, C_CAP_R, C_CAP_R, C_TOWER_Z1, C_CAP_Z1), M_HULL)


def add_breach(b, rng):
    """Torn plate splayed around the missing panel, plus an exposed conduit."""
    ac = BREACH_FACET * TAU / NSIDE
    for i in range(3):
        t = (i - 1) * 0.30 + rng.uniform(-0.04, 0.04)
        z = 0.44 + i * 0.13 + rng.uniform(-0.03, 0.03)
        lean = 0.45 + rng.uniform(-0.12, 0.12)
        m = xf(polar(0.94, ac, z), (0, 0, ac)) @ xf((0.02, t, 0), (lean, 0.22, 0))
        b.add(mk_box(0.18, 0.24, 0.030), M_HULL, 0.008, m)
    b.add(mk_box(0.04, 0.30, 0.045), M_ACCENT, 0.0,
          xf(polar(C_INNER_R + 0.02, ac, 0.60), (0, 0, ac)))


def add_patch(b, form):
    """Salvage plate riveted over the old breach — form 0's scar, kept visible."""
    a0, a1, ac = facet_span(BREACH_FACET, FACET_MARGIN - 0.030)
    b.add(mk_slab(a0, a1, C_PANEL_R0, C_PANEL_R1 + 0.03, 0.40, 0.74, ac), M_PLATE, 0.022)
    for sy in (-1, 1):
        for sz in (-1, 1):
            b.add(mk_box(0.06, 0.06, 0.06), M_HULL, 0.0,
                  xf(polar(C_PANEL_R1 + 0.04, ac, 0.57 + sz * 0.13), (0, 0, ac))
                  @ Matrix.Translation((0, sy * 0.26, 0)))
    if form >= 2:                          # form 2 armours straight over the patch
        b.add(mk_slab(a0, a1, C_PANEL_R1 + 0.03, C_PANEL_R1 + 0.11, 0.44, 0.70, ac),
              M_HULL, 0.016)


def add_graft(b, form):
    """Extra plating bolted onto the original pod's facets. Accretion, visible."""
    facets = [0, 2, 4, 6] if form == 1 else [0, 1, 3, 4, 5, 7]
    for i in facets:
        a0, a1, ac = facet_span(i, FACET_MARGIN + 0.045)
        b.add(mk_slab(a0, a1, C_PANEL_R1, C_PANEL_R1 + 0.09, 0.42, 0.72, ac),
              M_PLATE, 0.016)


def add_tier(b, pad_r, pad_h, sk, arm, wall_r, deck, vent_facets):
    """One ring of accreted armour: feet, skirt, plate ring, inner wall, deck."""
    sk_r0, sk_r1, sk_z0, sk_z1 = sk
    ar_r0, ar_r1, ar_z0, ar_z1 = arm
    dk_r0, dk_r1, dk_z0, dk_z1 = deck

    for i in range(4):
        a = i * TAU / 4.0 + (TAU / 8.0 if vent_facets else 0.0)
        b.add(mk_box(0.40, 0.30, pad_h), M_PLATE, 0.020,
              xf(polar(pad_r, a, pad_h * 0.5), (0, 0, a)))

    b.add(mk_prism(NSIDE, sk_r0, sk_r1, sk_z0, sk_z1, cap1=False), M_PLATE)

    for i in range(NSIDE):
        a0, a1, ac = facet_span(i)
        if i in vent_facets:
            # split the plate so a recessed vent band shows through the gap
            b.add(mk_slab(a0, a1, ar_r0, ar_r1, ar_z0, T2_VENT_Z0, ac), M_HULL, 0.028)
            b.add(mk_slab(a0, a1, ar_r0, ar_r1, T2_VENT_Z1, ar_z1, ac), M_HULL, 0.028)
            ac = i * TAU / NSIDE
            zc = (T2_VENT_Z0 + T2_VENT_Z1) * 0.5
            b.add(mk_box(0.16, 0.60, 0.15), M_PLATE, 0.0,
                  xf(polar(ar_r0 + 0.07, ac, zc), (0, 0, ac)))
            for s in (-1, 0, 1):
                b.add(mk_box(0.03, 0.50, 0.026), M_ACCENT, 0.0,
                      xf(polar(ar_r0 + 0.15, ac, zc + s * 0.045), (0, 0, ac)))
        else:
            b.add(mk_slab(a0, a1, ar_r0, ar_r1, ar_z0, ar_z1, ac), M_HULL, 0.028)

    b.add(mk_prism(NSIDE, wall_r, wall_r, dk_z0 - 0.22, dk_z1, cap0=False,
                   cap1=False), M_PLATE)
    for i in range(NSIDE):
        a0, a1, ac = facet_span(i, 0.008)
        b.add(mk_slab(a0, a1, dk_r0, dk_r1, dk_z0, dk_z1, ac), M_PLATE)


def add_mast(b, ang, r, sensor):
    """Form 1 gets a comms mast; form 2 grows it into a sensor mast."""
    base = xf(polar(r, ang, C_DECK_Z), (0, 0, ang))
    b.add(mk_box(0.32, 0.32, 0.10), M_PLATE, 0.016, base @ Matrix.Translation((0, 0, 0.05)))
    if not sensor:
        b.add(mk_box(0.16, 0.16, 0.95), M_HULL, 0.020, base @ Matrix.Translation((0, 0, 0.575)))
        b.add(mk_box(0.24, 0.24, 0.07), M_PLATE, 0.0, base @ Matrix.Translation((0, 0, 0.50)))
        b.add(mk_box(0.10, 0.10, 0.16), M_HULL, 0.012, base @ Matrix.Translation((0, 0, 1.13)))
        b.add(mk_box(0.09, 0.09, 0.09), M_ACCENT, 0.0, base @ Matrix.Translation((0, 0, 1.255)))
        b.add(mk_box(0.06, 0.06, 0.62), M_PLATE, 0.0,
              base @ xf((0.17, 0, 0.42), (0, 0.42, 0)))
        return C_DECK_Z + 1.30
    b.add(mk_box(0.18, 0.18, 1.30), M_HULL, 0.022, base @ Matrix.Translation((0, 0, 0.75)))
    b.add(mk_box(0.26, 0.26, 0.08), M_PLATE, 0.0, base @ Matrix.Translation((0, 0, 0.66)))
    b.add(mk_box(0.11, 0.11, 0.30), M_HULL, 0.012, base @ Matrix.Translation((0, 0, 1.55)))
    b.add(mk_prism(6, 0.26, 0.17, 1.70, 1.90), M_HULL, 0.0, base)
    b.add(mk_prism(6, 0.28, 0.28, 1.76, 1.82, cap0=False, cap1=False), M_ACCENT, 0.0, base)
    b.add(mk_box(0.08, 0.08, 0.10), M_ACCENT, 0.0, base @ Matrix.Translation((0, 0, 1.95)))
    b.add(mk_box(0.06, 0.06, 0.85), M_PLATE, 0.0, base @ xf((0.22, 0, 0.55), (0, 0.42, 0)))
    return C_DECK_Z + 2.00


# ------------------------------------------------------------------ build ----
bpy.ops.wm.read_factory_settings(use_empty=True)


EMIT_BASE = hex_linear("0a1518")   # near-black body so cyan reads as light
EMIT_STRENGTH = 4.0


def make_mat(name, colour, emit=False):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = colour if not emit else EMIT_BASE
    bsdf.inputs["Roughness"].default_value = 0.45 if emit else 0.72
    bsdf.inputs["Metallic"].default_value = 0.0 if emit else 0.65
    if emit:
        bsdf.inputs["Emission Color"].default_value = colour
        bsdf.inputs["Emission Strength"].default_value = EMIT_STRENGTH
    return m


MATS = [make_mat("sentinel_hull", HULL),
        make_mat("sentinel_plate", PLATE),
        make_mat("sentinel_accent", ACCENT, emit=True)]

built = []
for form in range(3):
    rng = random.Random(SEED + form)       # deterministic: fixed seed per form
    spec = FORM_SPEC[form]
    b = Build("module_form_%d" % form)

    add_core_drum(b, patched=(form >= 1))
    if form == 0:
        add_breach(b, rng)
    else:
        add_patch(b, form)
        add_graft(b, form)
        # tier 1 apron
        add_tier(b, T1_PAD_R, T1_PAD_H,
                 (T1_SKIRT_R0, T1_SKIRT_R1, T1_SKIRT_Z0, T1_SKIRT_Z1),
                 (T1_ARM_R0, T1_ARM_R1, T1_ARM_Z0, T1_ARM_Z1),
                 T1_WALL_R,
                 (T1_DECK_R0, T1_DECK_R1, T1_DECK_Z0, T1_DECK_Z1),
                 vent_facets=())
        b.add(mk_prism(NSIDE, 0.26, 0.26, C_CAP_Z1, C_CAP_Z1 + 0.12), M_HULL)

    if form >= 2:
        add_tier(b, T2_PAD_R, T2_PAD_H,
                 (T2_SKIRT_R0, T2_SKIRT_R1, T2_SKIRT_Z0, T2_SKIRT_Z1),
                 (T2_ARM_R0, T2_ARM_R1, T2_ARM_Z0, T2_ARM_Z1),
                 T2_WALL_R,
                 (T2_DECK_R0, T2_DECK_R1, T2_DECK_Z0, T2_DECK_Z1),
                 vent_facets=(1, 3, 5, 7))
        b.add(mk_prism(NSIDE, 0.22, 0.22, C_CAP_Z1 + 0.12, C_CAP_Z1 + 0.24), M_HULL)

    # hatches: one more with every stage
    hatches = [(math.radians(30), 0.62, C_DECK_Z),
               (math.radians(150), 1.40, T1_DECK_Z1),
               (math.radians(270), 2.05, T2_DECK_Z1)][:form + 1]
    for ang, r, z in hatches:
        add_hatch(b, ang, r, z)

    if form == 0:
        dock_at = add_dock(b, math.radians(270), 0.62, C_DECK_Z)
    elif form == 1:
        dock_at = add_dock(b, math.radians(270), 1.40, T1_DECK_Z1)
    else:
        dock_at = add_dock(b, math.radians(210), 2.02, T2_DECK_Z1)

    top = C_CAP_Z1
    if form == 1:
        top = add_mast(b, math.pi, 0.58, sensor=False)
    elif form == 2:
        top = add_mast(b, math.pi, 0.58, sensor=True)

    ob, ntri = b.bake(MATS)
    built.append((ob, ntri, spec, top))

    # --- attach points ------------------------------------------------------
    # Six bays ringed on the upper deck of that form, sitting ON the deck skin
    # so they stay visible from the top-down RTS camera. Blender local +Y is the
    # outward direction, which becomes Godot's forward (-Z) after the glTF Y-up
    # conversion, so a module reparented here already faces off the deck.
    for i in range(BAYS):
        a = i * TAU / BAYS
        e = bpy.data.objects.new("bay_%d_%d" % (form, i), None)
        e.empty_display_type = 'ARROWS'
        e.empty_display_size = 0.30
        e.location = polar(spec["bay_r"], a, spec["bay_z"])
        e.rotation_euler = (0.0, 0.0, a - math.pi * 0.5)
        bpy.context.collection.objects.link(e)
        e.parent = ob

    d = bpy.data.objects.new("drone_dock_%d" % form, None)
    d.empty_display_type = 'PLAIN_AXES'
    d.empty_display_size = 0.25
    d.location = dock_at
    bpy.context.collection.objects.link(d)
    d.parent = ob

    print("PY: built %s  parts=%d  tris(blender)=%d  top_z=%.3f"
          % (ob.name, len(b.parts), ntri, top))

# The sky, baked in, just before the file is written. module_forms carried no
# vertex colour at all until now.
sky_light_scene(load_sky(default_sky()))
_kw = dict(filepath=GLB, export_format='GLB',
           export_apply=False, export_yup=True,
           export_materials='EXPORT', use_selection=False)
# Without export_vertex_color the exporter drops COLOR_0, because the default
# emits only vertex colours a shader graph reads and these materials do not.
try:
    bpy.ops.export_scene.gltf(export_vertex_color='ACTIVE', **_kw)
except TypeError:
    bpy.ops.export_scene.gltf(**_kw)
print("PY: exported %s (%d bytes)" % (GLB, os.path.getsize(GLB)))

# =============================================================== VERIFY ======
# Parse the glb we just wrote. Nothing above is trusted; every claim is
# re-derived from the exported bytes.
with open(GLB, "rb") as fh:
    magic, ver, total = struct.unpack("<4sII", fh.read(12))
    assert magic == b"glTF", "not a glb"
    doc = None
    while fh.tell() < total:
        clen, ctype = struct.unpack("<II", fh.read(8))
        data = fh.read(clen)
        if ctype == 0x4E4F534A:
            doc = json.loads(data.decode("utf-8"))
    assert doc is not None, "no JSON chunk"

nodes = doc.get("nodes", [])
names = [n.get("name", "") for n in nodes]
meshes = doc.get("meshes", [])
accs = doc.get("accessors", [])
print("PY: glb version=%d nodes=%d meshes=%d materials=%d"
      % (ver, len(nodes), len(meshes), len(doc.get("materials", []))))

fails = []
BUDGET = 4000
report = {}

for form in range(3):
    fname = "module_form_%d" % form
    if fname not in names:
        fails.append("missing node %s" % fname)
        continue
    ni = names.index(fname)
    node = nodes[ni]

    if "mesh" not in node:
        fails.append("%s has no mesh" % fname)
        continue
    mesh = meshes[node["mesh"]]

    tris = 0
    lo = [1e9, 1e9, 1e9]
    hi = [-1e9, -1e9, -1e9]
    for prim in mesh["primitives"]:
        if "indices" in prim:
            tris += accs[prim["indices"]]["count"] // 3
        else:
            tris += accs[prim["attributes"]["POSITION"]]["count"] // 3
        pa = accs[prim["attributes"]["POSITION"]]
        for k in range(3):
            lo[k] = min(lo[k], pa["min"][k])
            hi[k] = max(hi[k], pa["max"][k])

    # glTF is Y-up: X = width, Z = depth, Y = height.
    w, h, d = hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]
    print("PY: %s tris=%d/%d  bbox X=%.3f m  Z=%.3f m  Y(height)=%.3f m  "
          "Ymin=%.4f  Xcen=%+.4f  Zcen=%+.4f"
          % (fname, tris, BUDGET, w, d, h, lo[1],
             (hi[0] + lo[0]) * 0.5, (hi[2] + lo[2]) * 0.5))
    report[fname] = dict(tris=tris, w=w, d=d, h=h,
                         prims=len(mesh["primitives"]))

    if tris > BUDGET:
        fails.append("%s over triangle budget: %d > %d" % (fname, tris, BUDGET))
    target = FORM_SPEC[form]["width"]
    for axis, val in (("X", w), ("Z", d)):
        if abs(val - target) > target * 0.02:
            fails.append("%s %s footprint %.3f m, intended %.2f m"
                         % (fname, axis, val, target))
    if abs(lo[1]) > 0.002:
        fails.append("%s ground contact off: Ymin=%.4f (origin must be at feet)"
                     % (fname, lo[1]))
    for axis, c in (("X", (hi[0] + lo[0]) * 0.5), ("Z", (hi[2] + lo[2]) * 0.5)):
        if abs(c) > 0.02:
            fails.append("%s not centred in %s: %.4f" % (fname, axis, c))

    # children: six bays + one dock, by exact name, with real transforms
    kids = [names[c] for c in node.get("children", [])]
    want = ["bay_%d_%d" % (form, i) for i in range(BAYS)] + ["drone_dock_%d" % form]
    for wname in want:
        if wname not in kids:
            fails.append("%s missing child node %s" % (fname, wname))
    print("PY: %s children (%d): %s" % (fname, len(kids), ", ".join(sorted(kids))))

    deck_y = FORM_SPEC[form]["bay_z"]
    ring = []
    for i in range(BAYS):
        bn = "bay_%d_%d" % (form, i)
        if bn not in names:
            continue
        t = nodes[names.index(bn)].get("translation", [0.0, 0.0, 0.0])
        ring.append((bn, t))
        if abs(t[1] - deck_y) > 0.002:
            fails.append("%s deck height %.3f, expected %.3f" % (bn, t[1], deck_y))
        rad = math.hypot(t[0], t[2])
        if abs(rad - FORM_SPEC[form]["bay_r"]) > 0.002:
            fails.append("%s ring radius %.3f, expected %.3f"
                         % (bn, rad, FORM_SPEC[form]["bay_r"]))
        if rad > (w * 0.5) or rad < 0.2:
            fails.append("%s not on the deck (r=%.3f)" % (bn, rad))
    print("PY: %s bay ring r=%.3f m at deck height %.3f m, %d anchors"
          % (fname, FORM_SPEC[form]["bay_r"], deck_y, len(ring)))

    dn = "drone_dock_%d" % form
    if dn in names:
        t = nodes[names.index(dn)].get("translation", [0, 0, 0])
        print("PY: %s at (%.3f, %.3f, %.3f) glTF-xyz, %.3f m from centre"
              % (dn, t[0], t[1], t[2], math.hypot(t[0], t[2])))

def lin_to_srgb(c):
    return c * 12.92 if c <= 0.0031308 else 1.055 * (c ** (1.0 / 2.4)) - 0.055


want_hex = {"sentinel_hull": HULL_HEX, "sentinel_plate": PLATE_HEX,
            "sentinel_accent": None}
for mat in doc.get("materials", []):
    b = mat["pbrMetallicRoughness"].get("baseColorFactor", [1, 1, 1, 1])
    got = "%02x%02x%02x" % tuple(round(lin_to_srgb(x) * 255) for x in b[:3])
    exp = want_hex.get(mat["name"])
    print("PY: material %-16s baseColor displays as #%s%s"
          % (mat["name"], got, "" if exp is None else " (palette #%s)" % exp))
    if exp is not None and got != exp:
        fails.append("%s exports as #%s, palette says #%s" % (mat["name"], got, exp))
    if mat["name"] == "sentinel_accent":
        ef = mat.get("emissiveFactor", [0, 0, 0])
        st = mat.get("extensions", {}).get(
            "KHR_materials_emissive_strength", {}).get("emissiveStrength", 1.0)
        # the exporter normalises emissiveFactor to max 1 and moves the scale
        # into emissiveStrength, so undo that to recover the authored colour
        eh = "%02x%02x%02x" % tuple(
            round(lin_to_srgb(min(1.0, x * st / EMIT_STRENGTH)) * 255) for x in ef)
        print("PY: material sentinel_accent emission #%s at strength %.2f "
              "(palette #%s x%.1f)" % (eh, st, ACCENT_HEX, EMIT_STRENGTH))
        if eh != ACCENT_HEX:
            fails.append("accent emission hue #%s, palette says #%s" % (eh, ACCENT_HEX))

# no armature in this asset group — assert that honestly rather than implying one
if "skins" in doc:
    fails.append("unexpected skins array: this asset group is unrigged")
print("PY: skins=%s animations=%s (module is static geometry, by design)"
      % ("skins" in doc, "animations" in doc))

total_nodes_wanted = 3 + 3 * (BAYS + 1)
print("PY: named nodes present = %d/%d"
      % (sum(1 for n in (["module_form_%d" % f for f in range(3)]
                         + ["bay_%d_%d" % (f, i) for f in range(3) for i in range(BAYS)]
                         + ["drone_dock_%d" % f for f in range(3)])
             if n in names), total_nodes_wanted))

if fails:
    for f in fails:
        print("PY: FAIL %s" % f)
    raise SystemExit("VERIFY FAILED: %d problem(s)" % len(fails))
print("PY: OK all assertions passed")
