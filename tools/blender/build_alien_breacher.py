"""SENTINEL — procedural alien breacher (rigged + animated).

Alien type 2: the slow heavy one that breaks structures. ~1.8 m nose-to-tail,
bulky, four thick legs, a heavy armoured head shield it leads with, hunched
shoulders. Built from explicit triangle lists so the triangle count is known
exactly before export and can be asserted against the exported glTF.

    ~/.cache/blender-venv/bin/python tools/blender/build_alien_breacher.py [out_dir]

Silhouette contract (why this reads differently to the swarmer at RTS range)
  swarmer   0.8 m long, 0.3 m tall, six thin legs, narrow wedge, knees level
  breacher  1.8 m long, 1.0 m tall, four thick legs, wide flared ram shield at
            the front and a dorsal hump over the shoulders behind it
  So: twice the length, three times the height, half the leg count, and the
  mass sits forward. At 30 px on a phone the pair differ in aspect ratio and
  in where the bulk is, not just in detail — which is what survives downscaling.

Conventions (project asset pass)
  * metres, Z-up in Blender; the glTF exporter converts to Y-up for Godot
  * origin at the ground contact point (hoof soles sit at z = 0), centred in XY
  * solid colours + emission only, no UVs, no textures
  * fully deterministic: no random calls anywhere, no timestamps

Authoring space
  Authored with "forward" = +X because that keeps the profile lists readable as
  (forward, up) pairs. Godot's forward is -Z and the glTF exporter maps Blender
  (x, y, z) -> glTF (x, z, -y), so Blender +Y is the axis that lands on glTF
  -Z. ORIENT is the quarter turn taking authored +X forward onto Blender +Y,
  baked into vertices and bone rest positions rather than left on a node
  transform, so the exported nodes keep identity rotations. Left-side parts are
  authored once at +Y and emitted twice; the mirror matrix has a negative
  determinant so _emit flips the winding to keep normals out.

Rig — exactly what the asset brief asks for, 11 bones
  root -> spine -> head
  root -> leg_{fl,fr,bl,br}_femur -> ..._tibia
  All four legs hang off root rather than off spine. Anatomically the front
  pair belong to the shoulders, but with no IK anything parented under spine
  gets dragged wherever the chest goes, and the slam pitches the chest hard:
  the first build put the front hooves 0.18 m through the ground on the
  follow-through. Root-parented legs let the chest pitch against planted front
  legs, which is what a real animal bracing for an impact does anyway.
  Three baked actions: 'idle', 'walk', 'slam'.

  'walk' is a lateral-sequence four-beat walk (LF, RH, RF, LH at 0, 1/4, 1/2,
  3/4) with a 0.75 duty factor, which is the gait a heavy quadruped actually
  uses — three feet down at every instant. A trot would read as "fast".

  'slam' reads a signed drive envelope: -1 reared back, 0 rest, +1 shield
  driven into the ground. The rear-up rotates root about a pivot placed on the
  ground between the two rear hooves, so the rear feet stay planted while the
  front end lifts, instead of the whole animal floating.

Pose maths
  Poses are authored as world-space rotations about a world axis through a
  chosen pivot, converted to the bone-local basis Blender wants with
      matrix_basis = rest_local^-1 @ W @ rest_local
  which follows from pose = pose_parent @ rest_parent^-1 @ rest @ basis. A
  leg's swing axis is then "world up" and its lift axis is "horizontal,
  perpendicular to the leg" — both readable — rather than whatever the bone
  roll came out as.
"""
import bpy, sys, os, math, struct, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _ao import default_sky, load_sky, sky_light_scene   # noqa: E402
from mathutils import Matrix, Vector, Quaternion

from _bl import script_args  # noqa: F401  (kept so both front ends work)

argv = script_args()
OUT = os.path.abspath(argv[0] if argv else "models")
os.makedirs(OUT, exist_ok=True)

TRI_BUDGET = 900                 # hard limit for one alien
FPS = 24
TAU = math.tau


# --- palette ----------------------------------------------------------------
# The hexes in the brief are sRGB. glTF baseColorFactor / emissiveFactor are
# LINEAR, so convert; feeding the raw sRGB bytes in as linear renders roughly
# two stops too dark.
def _s2l(b):
    c = b / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def hexcol(h):
    return tuple(_s2l(int(h[i:i + 2], 16)) for i in (0, 2, 4)) + (1.0,)


CHITIN_HEX, FLESH_HEX, GLOW_HEX = "8a3a52", "c2415e", "ffb0c0"
CHITIN, FLESH, GLOW = 0, 1, 2            # material slot indices


def set_in(bsdf, name, value):
    if name in bsdf.inputs:
        bsdf.inputs[name].default_value = value


def make_materials():
    mats = []
    for name, hexv, rough, metal, emit in (
        ("alien_chitin", CHITIN_HEX, 0.42, 0.05, False),
        ("alien_flesh",  FLESH_HEX,  0.68, 0.00, False),
        ("alien_glow",   GLOW_HEX,   0.30, 0.00, True),
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
_HEXA_QUADS = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4),
               (3, 7, 6, 2), (0, 4, 7, 3), (1, 2, 6, 5)]


def g_hexa(pts):
    """8 corners ordered [-y bottom, +y bottom, +y top, -y top] at x0 then x1."""
    t = []
    for a, b, c, d in _HEXA_QUADS:
        t += [(a, b, c), (a, c, d)]
    return list(pts), t                                  # 12 tris


def seg_pts(x0, x1, w0, w1, zb0, zt0, zb1, zt1):
    """A tapered body segment: half-widths w, bottom/top z at each end."""
    return [(x0, -w0, zb0), (x0, w0, zb0), (x0, w0, zt0), (x0, -w0, zt0),
            (x1, -w1, zb1), (x1, w1, zb1), (x1, w1, zt1), (x1, -w1, zt1)]


def plate_pts(x0, x1, q0, q1):
    """A one-sided armour plate: an arbitrary (y, z) quad at two x stations.

    q is four (y, z) corners ordered lo-lo, hi-lo, hi-hi, lo-hi so the result
    matches g_hexa's expected corner order.
    """
    return [(x0, y, z) for (y, z) in q0] + [(x1, y, z) for (y, z) in q1]


def box_pts(c, s):
    """An axis-aligned box of size `s` centred on `c` — all three axes.

    seg_pts is symmetric about y = 0 by construction (it takes half-widths,
    not a y centre), so the y offset has to be added afterwards. Forgetting
    that silently builds every off-centre box on the centre line instead:
    it cost an afternoon here, with four hooves buried in the abdomen and a
    walk cycle whose feet would not lift because they were sitting on the
    rotation axis.
    """
    hx, hy, hz = s[0] * 0.5, s[1] * 0.5, s[2] * 0.5
    pts = seg_pts(c[0] - hx, c[0] + hx, hy, hy,
                  c[2] - hz, c[2] + hz, c[2] - hz, c[2] + hz)
    return [(x, y + c[1], z) for (x, y, z) in pts]


def _ring_faces(n):
    """Caps + sides for two n-vertex rings (first 0..n-1, second n..2n-1)."""
    t = []
    for i in range(1, n - 1):
        t.append((0, i + 1, i))
    for i in range(1, n - 1):
        t.append((n, n + i, n + i + 1))
    for i in range(n):
        j = (i + 1) % n
        t += [(i, j, n + j), (i, n + j, n + i)]
    return t                                             # 4n - 4 tris


def _basis(d):
    """Orthonormal (u, v, d) with d the given direction."""
    d = Vector(d).normalized()
    a = Vector((0.0, 0.0, 1.0)) if abs(d.z) < 0.9 else Vector((1.0, 0.0, 0.0))
    u = a.cross(d).normalized()
    v = d.cross(u)
    return u, v, d


def g_tube(p0, p1, r0, r1, n):
    """Tapered n-sided prism from p0 to p1 (4n - 4 tris)."""
    p0, p1 = Vector(p0), Vector(p1)
    u, v, _ = _basis(p1 - p0)
    vs = []
    for p, r in ((p0, r0), (p1, r1)):
        for i in range(n):
            a = i * TAU / n
            vs.append(tuple(p + u * (r * math.cos(a)) + v * (r * math.sin(a))))
    return vs, _ring_faces(n)


def g_spike(base, tip, r, n):
    """n-sided cone, apex exactly at `tip` (2n - 2 tris)."""
    base, tip = Vector(base), Vector(tip)
    u, v, _ = _basis(tip - base)
    vs = []
    for i in range(n):
        a = i * TAU / n
        vs.append(tuple(base + u * (r * math.cos(a)) + v * (r * math.sin(a))))
    vs.append(tuple(tip))
    t = [(0, i + 1, i) for i in range(1, n - 1)]
    t += [(i, (i + 1) % n, n) for i in range(n)]
    return vs, t


# --- transforms --------------------------------------------------------------
ORIENT = Matrix.Rotation(math.pi * 0.5, 4, 'Z')     # authored +X -> Blender +Y
MIRROR = Matrix.Diagonal(Vector((1.0, -1.0, 1.0, 1.0)))
SIDE_M = {1: ORIENT, -1: ORIENT @ MIRROR}

FWD = Vector((0.0, 1.0, 0.0))      # Blender axis that becomes glTF -Z
LAT = Vector((1.0, 0.0, 0.0))      # pitch axis
UP = Vector((0.0, 0.0, 1.0))       # yaw axis


class MB:
    """Accumulates triangles, per-triangle material index, per-vertex weights."""

    def __init__(self):
        self.v, self.f, self.m, self.w = [], [], [], []

    def _emit(self, verts, tris, mat, M, wts):
        off = len(self.v)
        flip = M.determinant() < 0.0
        for i, p in enumerate(verts):
            self.v.append(tuple(M @ Vector(p)))
            if callable(wts):
                d = wts(p)
            elif isinstance(wts, (list, tuple)):
                d = wts[i]
            else:
                d = wts
            self.w.append(dict(d))
        for t in tris:
            tt = (t[0], t[2], t[1]) if flip else t
            self.f.append(tuple(off + k for k in tt))
            self.m.append(mat)

    def hexa(self, mat, pts, wts, M=ORIENT):
        v, t = g_hexa(pts)
        self._emit(v, t, mat, M, wts)

    def seg(self, mat, args, wts, M=ORIENT):
        self.hexa(mat, seg_pts(*args), wts, M)

    def plate(self, mat, x0, x1, q0, q1, wts, M=ORIENT):
        self.hexa(mat, plate_pts(x0, x1, q0, q1), wts, M)

    def box(self, mat, c, s, wts, M=ORIENT):
        self.hexa(mat, box_pts(c, s), wts, M)

    def tube(self, mat, p0, p1, r0, r1, n, w0, w1, M=ORIENT):
        v, t = g_tube(p0, p1, r0, r1, n)
        self._emit(v, t, mat, M, [w0] * n + [w1] * n)

    def spike(self, mat, base, tip, r, n, w, M=ORIENT):
        v, t = g_spike(base, tip, r, n)
        self._emit(v, t, mat, M, w)

    @property
    def tris(self):
        return len(self.f)


# =============================================================================
# BREACHER — geometry
# =============================================================================
# Hip / knee / hoof-centre for the two LEFT legs. Right legs are the Y mirror.
# Knees ride above the body's belly line (chitinous posture) but below the
# carapace, so the animal still reads as low-slung rather than stilted.
LEGS = {
    "f": ((0.38,  0.20, 0.58), (0.56,  0.44, 0.74), (0.60,  0.40, 0.0)),
    "b": ((-0.34, 0.19, 0.55), (-0.54, 0.45, 0.70), (-0.58, 0.42, 0.0)),
}
# Every leg hangs off root, not off spine. Anatomically the front pair belong
# to the shoulders, but with no IK a spine-parented front leg gets dragged
# wherever the chest goes: the first build had the slam's -0.24 rad chest pitch
# push the front hooves 0.18 m through the ground, and the idle's breathing
# lift them 64 mm. Parenting them to root makes the chest pitch against planted
# front legs, which is also what a real animal bracing for an impact does.
LEG_PARENT = {"f": "root", "b": "root"}
SIDES = ((1, "l"), (-1, "r"))
POSNS = ("f", "b")

HOOF_H = 0.09                       # hoof block height; ankle sits on its top
HOOF_S = (0.20, 0.17, HOOF_H)
FEM_R0, FEM_R1 = 0.085, 0.065       # thick — this is the heavy alien
TIB_R0, TIB_R1 = 0.070, 0.050
KNEE_R0, KNEE_R1 = 0.080, 0.074
CLAW_R = 0.040


def clamp01(x):
    return 0.0 if x < 0.0 else (1.0 if x > 1.0 else x)


def body_w(p):
    """Smooth root / spine / head weights from the authored x coordinate.

    Blend bands rather than per-part rigid assignment, so the waist and the
    neck bend instead of shearing when the spine pitches for the slam. With
    only three body bones the bands are wide on purpose: the neck band is the
    one that matters, because it is the one the slam drives hardest.
    """
    x = p[0]
    wh = clamp01((x - 0.46) / 0.16)          # 0 behind x=0.46, 1 ahead of 0.62
    wr = clamp01((-0.06 - x) / 0.26)         # 1 behind x=-0.32, 0 ahead of -0.06
    ws = max(0.0, 1.0 - wh - wr)
    tot = wh + wr + ws
    d = {}
    if wr > 1e-6:
        d["root"] = wr / tot
    if ws > 1e-6:
        d["spine"] = ws / tot
    if wh > 1e-6:
        d["head"] = wh / tot
    return d


def ankle_of(knee, foot):
    """Point on the knee->foot line at the top of the hoof block."""
    k, f = Vector(knee), Vector(foot)
    return k.lerp(f, (k.z - HOOF_H) / (k.z - f.z))


def build_body(b):
    """Everything symmetric about the centre line. 12 tris per hexahedron."""
    W = body_w
    # --- thorax, shoulder hump, neck ---------------------------------------
    b.seg(CHITIN, (-0.12, 0.10, 0.26, 0.28, 0.48, 0.84, 0.50, 0.88), W)
    b.seg(CHITIN, (0.10, 0.34, 0.28, 0.30, 0.50, 0.88, 0.50, 0.94), W)
    b.seg(CHITIN, (0.34, 0.52, 0.30, 0.24, 0.50, 0.94, 0.54, 0.82), W)
    b.seg(FLESH,  (0.52, 0.64, 0.24, 0.21, 0.54, 0.82, 0.58, 0.78), W)

    # --- abdomen: four tapering chitin segments ----------------------------
    b.seg(CHITIN, (-0.34, -0.12, 0.25, 0.26, 0.46, 0.82, 0.48, 0.84), W)
    b.seg(CHITIN, (-0.56, -0.34, 0.22, 0.25, 0.45, 0.78, 0.46, 0.82), W)
    b.seg(CHITIN, (-0.72, -0.56, 0.16, 0.22, 0.47, 0.71, 0.45, 0.78), W)
    b.seg(CHITIN, (-0.82, -0.72, 0.07, 0.16, 0.53, 0.63, 0.47, 0.71), W)

    # --- overlapping dorsal armour plates, the hunched back ----------------
    b.seg(CHITIN, (0.06, 0.30, 0.30, 0.32, 0.84, 0.90, 0.88, 0.97), W)
    b.seg(CHITIN, (-0.20, 0.06, 0.28, 0.30, 0.80, 0.87, 0.84, 0.92), W)
    b.seg(CHITIN, (-0.46, -0.20, 0.24, 0.28, 0.76, 0.83, 0.80, 0.88), W)
    b.seg(CHITIN, (-0.68, -0.46, 0.18, 0.24, 0.70, 0.77, 0.76, 0.84), W)

    # --- belly (soft, the thing the player is meant to want to shoot) ------
    b.seg(FLESH, (-0.60, 0.16, 0.21, 0.24, 0.44, 0.56, 0.47, 0.59), W)
    b.seg(FLESH, (0.16, 0.48, 0.24, 0.20, 0.47, 0.59, 0.52, 0.62), W)

    # --- dorsal glow seam running the length of the crest ------------------
    b.seg(GLOW, (-0.52, 0.24, 0.040, 0.050, 0.79, 0.87, 0.88, 0.99), W)

    # --- head shield: the part it leads with --------------------------------
    b.seg(CHITIN, (0.64, 0.72, 0.21, 0.27, 0.50, 0.78, 0.46, 0.80), W)
    b.seg(CHITIN, (0.72, 0.88, 0.27, 0.35, 0.46, 0.80, 0.44, 0.74), W)
    b.seg(CHITIN, (0.86, 0.94, 0.19, 0.15, 0.50, 0.70, 0.53, 0.66), W)
    b.seg(FLESH,  (0.68, 0.86, 0.18, 0.14, 0.34, 0.50, 0.33, 0.46), W)
    b.seg(GLOW,   (0.78, 0.90, 0.100, 0.065, 0.375, 0.455, 0.375, 0.435), W)


def build_sided(b, s, side, M):
    """Everything that exists once per side. Authored at +Y, mirrored to -Y."""
    W = body_w
    H = {"head": 1.0}

    # --- shoulder pauldron riding over the hump -----------------------------
    b.plate(CHITIN, 0.08, 0.36,
            [(0.20, 0.80), (0.33, 0.71), (0.32, 0.79), (0.19, 0.89)],
            [(0.20, 0.82), (0.35, 0.73), (0.34, 0.81), (0.19, 0.92)], W, M)
    # --- flank armour plate -------------------------------------------------
    b.plate(CHITIN, -0.36, 0.04,
            [(0.24, 0.56), (0.30, 0.60), (0.29, 0.76), (0.23, 0.80)],
            [(0.25, 0.58), (0.31, 0.62), (0.30, 0.80), (0.24, 0.84)], W, M)
    # --- flank glow vent, proud of the plate so it actually shows -----------
    b.box(GLOW, (-0.16, 0.315, 0.68), (0.36, 0.030, 0.055), W, M)
    # --- swept-back dorsal spines flanking the crest ------------------------
    b.spike(CHITIN, (0.02, 0.13, 0.93), (-0.16, 0.20, 1.00), 0.045, 4, W, M)
    b.spike(CHITIN, (-0.28, 0.15, 0.85), (-0.46, 0.21, 0.92), 0.038, 4, W, M)
    # --- shield cheek wing --------------------------------------------------
    b.plate(CHITIN, 0.70, 0.90,
            [(0.28, 0.50), (0.36, 0.54), (0.35, 0.68), (0.27, 0.74)],
            [(0.33, 0.50), (0.42, 0.55), (0.41, 0.64), (0.32, 0.70)], H, M)
    # --- brow horn ----------------------------------------------------------
    b.spike(CHITIN, (0.80, 0.22, 0.72), (0.96, 0.14, 0.62), 0.050, 4, H, M)
    # --- eye pod on the front face of the shield ----------------------------
    b.plate(GLOW, 0.87, 0.93,
            [(0.21, 0.62), (0.30, 0.60), (0.30, 0.68), (0.21, 0.70)],
            [(0.20, 0.60), (0.27, 0.58), (0.27, 0.65), (0.20, 0.67)], H, M)
    # --- jaw tusk under the ram plate ---------------------------------------
    b.spike(CHITIN, (0.80, 0.12, 0.40), (0.95, 0.16, 0.34), 0.035, 4, H, M)

    # --- legs ---------------------------------------------------------------
    for pos in POSNS:
        hip, knee, foot = LEGS[pos]
        key = "%s%s" % (pos, side)
        par = LEG_PARENT[pos]
        fem = "leg_%s_femur" % key
        tib = "leg_%s_tibia" % key
        ankle = ankle_of(knee, foot)
        hoof_c = (ankle.x, ankle.y, HOOF_H * 0.5)

        b.box(FLESH, (hip[0], hip[1] + 0.02, hip[2]), (0.17, 0.16, 0.17),
              {par: 0.40, fem: 0.60}, M)
        b.tube(CHITIN, hip, knee, FEM_R0, FEM_R1, 5,
               {par: 0.25, fem: 0.75}, {fem: 0.70, tib: 0.30}, M)
        kn = Vector(knee)
        b.tube(CHITIN, kn.lerp(Vector(hip), 0.14), kn.lerp(ankle, 0.14),
               KNEE_R0, KNEE_R1, 4, {fem: 0.50, tib: 0.50},
               {fem: 0.50, tib: 0.50}, M)
        b.tube(CHITIN, knee, tuple(ankle), TIB_R0, TIB_R1, 5,
               {fem: 0.20, tib: 0.80}, {tib: 1.0}, M)
        b.box(CHITIN, hoof_c, HOOF_S, {tib: 1.0}, M)
        # The claw's base ring is perpendicular to its axis, so it sweeps
        # below its own base point. Seated at z = 0.055 with r = 0.040 the
        # lowest ring vertex lands at 0.017 — above the sole, which keeps the
        # sole the only thing touching z = 0 and keeps the origin contract
        # meaning what it says.
        b.spike(CHITIN, (hoof_c[0] + 0.10, hoof_c[1], 0.055),
                (hoof_c[0] + 0.20, hoof_c[1], 0.020), CLAW_R, 4,
                {tib: 1.0}, M)


def build_mesh():
    b = MB()
    build_body(b)
    for s, side in SIDES:
        build_sided(b, s, side, SIDE_M[s])
    return b


# =============================================================================
# rig
# =============================================================================
def bone_defs():
    """(name, parent, head, tail, connected) in AUTHORED space (+X forward)."""
    defs = [
        ("root",  None,    (0.000, 0.0, 0.000), (0.000, 0.0, 0.300), False),
        ("spine", "root",  (-0.100, 0.0, 0.620), (0.480, 0.0, 0.700), False),
        ("head",  "spine", (0.480, 0.0, 0.700), (0.940, 0.0, 0.600), True),
    ]
    for s, side in SIDES:
        for pos in POSNS:
            hip, knee, foot = LEGS[pos]
            mir = (lambda p: (p[0], p[1] * s, p[2]))
            key = "%s%s" % (pos, side)
            fem = "leg_%s_femur" % key
            tib = "leg_%s_tibia" % key
            defs.append((fem, LEG_PARENT[pos], mir(hip), mir(knee), False))
            defs.append((tib, fem, mir(knee), mir(foot), True))
    return defs


def build_armature(name, shift):
    arm = bpy.data.armatures.new("breacher_rig")
    ob = bpy.data.objects.new(name, arm)
    bpy.context.collection.objects.link(ob)
    bpy.context.view_layer.objects.active = ob
    ob.select_set(True)
    bpy.ops.object.mode_set(mode='EDIT')

    S = Matrix.Translation(Vector(shift))
    for bname, parent, head, tail, conn in bone_defs():
        eb = arm.edit_bones.new(bname)
        eb.head = S @ (ORIENT @ Vector(head))
        eb.tail = S @ (ORIENT @ Vector(tail))
        eb.roll = 0.0
        eb.use_deform = True
        if parent:
            eb.parent = arm.edit_bones[parent]
            eb.use_connect = conn
    bpy.ops.object.mode_set(mode='OBJECT')
    return ob


def skin(mesh_ob, arm_ob, weights):
    mesh_ob.parent = arm_ob
    mod = mesh_ob.modifiers.new("Armature", 'ARMATURE')
    mod.object = arm_ob
    mod.use_vertex_groups = True

    groups = {}
    for bone in arm_ob.data.bones:
        groups[bone.name] = mesh_ob.vertex_groups.new(name=bone.name)

    # batch by (bone, weight) so vertex_groups.add is called a few hundred
    # times rather than a few thousand
    batches = {}
    for i, wd in enumerate(weights):
        tot = sum(wd.values())
        if tot <= 0.0:
            raise SystemExit("FAIL: vertex %d has no weights" % i)
        for bname, w in wd.items():
            if bname not in groups:
                raise SystemExit("FAIL: weight on unknown bone %r" % bname)
            batches.setdefault((bname, round(w / tot, 5)), []).append(i)
    for (bname, w), idxs in sorted(batches.items()):
        groups[bname].add(idxs, w, 'REPLACE')
    return len(batches)


class Poser:
    """World-space pose authoring, converted to Blender's bone-local basis."""

    def __init__(self, arm_ob):
        self.ob = arm_ob
        self.rest = {b.name: b.matrix_local.copy() for b in arm_ob.data.bones}
        self.head = {b.name: b.head_local.copy() for b in arm_ob.data.bones}
        self.W = {}
        self.clear()

    def clear(self):
        self.W = {n: Matrix.Identity(4) for n in self.rest}

    def rot(self, name, axis, angle, pivot=None):
        p = self.head[name] if pivot is None else Vector(pivot)
        R = (Matrix.Translation(p)
             @ Matrix.Rotation(angle, 4, Vector(axis).normalized())
             @ Matrix.Translation(-p))
        self.W[name] = R @ self.W[name]

    def move(self, name, vec):
        self.W[name] = Matrix.Translation(Vector(vec)) @ self.W[name]

    def apply(self):
        for n, W in self.W.items():
            R = self.rest[n]
            pb = self.ob.pose.bones[n]
            pb.rotation_mode = 'QUATERNION'
            pb.matrix_basis = R.inverted() @ W @ R

    def key(self, frame):
        for n in self.rest:
            pb = self.ob.pose.bones[n]
            pb.keyframe_insert(data_path="location", frame=frame)
            pb.keyframe_insert(data_path="rotation_quaternion", frame=frame)


def leg_axes(arm_ob):
    """Per-leg swing sign and lift axis, derived from the rest pose.

    lift axis = horizontal, perpendicular to the leg, oriented so a positive
    angle raises the hoof.  swing sign = the sign of a world-Z rotation that
    carries the hoof FORWARD, which differs left vs right and is easy to get
    backwards by hand.
    """
    out = {}
    for s, side in SIDES:
        for pos in POSNS:
            key = "%s%s" % (pos, side)
            fem = arm_ob.data.bones["leg_%s_femur" % key]
            tib = arm_ob.data.bones["leg_%s_tibia" % key]
            d = (tib.tail_local - fem.head_local)
            dh = Vector((d.x, d.y, 0.0)).normalized()
            lift = dh.cross(UP).normalized()
            sign = 1.0 if UP.cross(dh).dot(FWD) > 0.0 else -1.0
            out[key] = {"lift": lift, "sign": sign}
    return out


def rear_ground_pivot(arm_ob):
    """Midpoint between the two rear hoof contacts, on the ground plane.

    The slam's rear-up rotates `root` about this, so the rear feet are the
    pivot and stay planted instead of the whole animal levitating.
    """
    ps = [arm_ob.data.bones["leg_b%s_tibia" % side].tail_local
          for _s, side in SIDES]
    m = (ps[0] + ps[1]) * 0.5
    return Vector((0.0, m.y, 0.0))


# =============================================================================
# animation
# =============================================================================
# Lateral-sequence four-beat walk: LF, RH, RF, LH. Duty factor 0.75 is chosen
# so the four swing windows tile the cycle exactly and never overlap — three
# hooves are on the ground at every instant, which is what makes a heavy
# quadruped read as heavy rather than as a scaled-up scuttler. At 0.70 two feet
# leave the ground together for 5% of the cycle and it starts to look springy.
LEG_PHASE = {"fl": 0.00, "br": 0.25, "fr": 0.50, "bl": 0.75}
WALK_ORDER = ("fl", "br", "fr", "bl")
STANCE = 0.75       # duty factor: fraction of the cycle the hoof is planted

SWING = 0.34        # rad, fore/aft femur sweep either side of neutral
FEM_LIFT = 0.18     # rad, peak femur lift during the swing phase
TIB_FLEX = 0.22     # rad, peak tibia fold during the swing phase
WALK_BOB = 0.005    # m, body rise/fall (four times per cycle, one per beat)


def smoothstep(f):
    return f * f * (3.0 - 2.0 * f)


def gait(u):
    """u in [0,1). -> (protraction, lift, flex).

    Stance (u < STANCE): hoof planted, sweeping back at constant speed.
    Swing  (u >= STANCE): hoof lifted, returning forward on a smoothstep.
    The velocity discontinuity at the ends is the hoof plant and the lift-off;
    it is meant to be there.
    """
    if u < STANCE:
        f = u / STANCE
        return SWING * (1.0 - 2.0 * f), 0.0, 0.0
    f = (u - STANCE) / (1.0 - STANCE)
    return (SWING * (2.0 * smoothstep(f) - 1.0),
            FEM_LIFT * math.sin(math.pi * f),
            math.sin(math.pi * f))


def pose_walk(P, axes, t):
    P.clear()
    w = TAU * t
    # root drags the planted hooves with it (no IK here) so its motion stays
    # small and the measured stance drift is asserted in verify_motion. spine
    # and head are above the legs in the hierarchy and cost nothing, so the
    # weight of the walk is carried there: a slow chest roll and a head that
    # lags it.
    P.move("root", (0.0, 0.0, WALK_BOB * math.sin(4.0 * w)))
    P.rot("root", UP, 0.030 * math.sin(w))
    P.rot("root", FWD, 0.016 * math.sin(w))
    P.rot("spine", UP, 0.060 * math.sin(w + 0.5))
    P.rot("spine", FWD, 0.055 * math.sin(w))
    P.rot("spine", LAT, 0.030 * math.sin(2.0 * w))
    P.rot("head", LAT, -0.070 * math.sin(2.0 * w + 0.9))
    P.rot("head", UP, 0.055 * math.sin(w + 1.2))
    for key, ax in axes.items():
        pro, lz, flex = gait((t + LEG_PHASE[key]) % 1.0)
        fem, tib = "leg_%s_femur" % key, "leg_%s_tibia" % key
        P.rot(fem, ax["lift"], lz)              # lift first, in the rest frame
        P.rot(fem, UP, pro * ax["sign"])        # then swing about true vertical
        P.rot(tib, ax["lift"], TIB_FLEX * flex)
    P.apply()


def pose_idle(P, axes, t):
    P.clear()
    w = TAU * t
    # Only root moves the hooves, so root breathes barely at all and the
    # visible life goes into the chest and the shield. The legs get a yaw-only
    # shift (yaw about world up cannot change a hoof's height) plus a token
    # tibia flex, so the animal shifts its weight without its feet floating.
    P.move("root", (0.0, 0.0, 0.004 * math.sin(w)))
    P.rot("root", LAT, 0.006 * math.sin(w))
    P.rot("spine", LAT, 0.030 * math.sin(w + 0.6))
    P.rot("spine", UP, 0.030 * math.sin(2.0 * w))
    P.rot("spine", FWD, 0.025 * math.sin(w + 2.0))
    P.rot("head", LAT, -0.075 * math.sin(w + 1.1))
    P.rot("head", UP, 0.070 * math.sin(2.0 * w + 0.4))
    for key, ax in axes.items():
        a = w + LEG_PHASE[key] * TAU
        fem, tib = "leg_%s_femur" % key, "leg_%s_tibia" % key
        P.rot(fem, UP, 0.016 * math.sin(a + 1.0) * ax["sign"])
        P.rot(tib, ax["lift"], 0.004 * math.sin(a + 0.5))
    P.apply()


# --- slam --------------------------------------------------------------------
# One signed envelope drives the whole attack, so the windup and the strike
# cannot drift out of sync: -1 fully reared, 0 rest, +1 shield in the dirt.
SLAM_REAR_END = 0.38        # reach the reared pose here
SLAM_HIT = 0.56             # shield bottoms out here
HEAD_UP, HEAD_DOWN = 0.36, 0.85       # rad
SPINE_UP, SPINE_DOWN = 0.14, 0.24     # rad
ROOT_UP = 0.12                        # rad, about the rear hoof pivot
ROOT_DIP = 0.010                      # m, impact compression


def slam_drive(t):
    if t < SLAM_REAR_END:
        return -smoothstep(t / SLAM_REAR_END)
    if t < SLAM_HIT:
        return -1.0 + 2.0 * smoothstep((t - SLAM_REAR_END)
                                       / (SLAM_HIT - SLAM_REAR_END))
    return 1.0 - smoothstep((t - SLAM_HIT) / (1.0 - SLAM_HIT))


def pose_slam(P, axes, t, pivot):
    P.clear()
    d = slam_drive(t)
    up, dn = max(-d, 0.0), max(d, 0.0)
    # Rear back about the rear hooves: the front end lifts, the rear feet are
    # the pivot and do not move. Coming down, root barely rotates — the force
    # comes from head and spine — so the front hooves do not punch through the
    # ground on the follow-through.
    P.rot("root", LAT, ROOT_UP * up, pivot)
    P.move("root", (0.0, 0.0, -ROOT_DIP * dn))
    P.rot("spine", LAT, SPINE_UP * up - SPINE_DOWN * dn)
    P.rot("head", LAT, HEAD_UP * up - HEAD_DOWN * dn)
    for key, ax in axes.items():
        fem, tib = "leg_%s_femur" % key, "leg_%s_tibia" % key
        if key.startswith("f"):
            # front legs tuck as the animal rears, then reach out on the strike
            P.rot(fem, ax["lift"], 0.12 * up)
            P.rot(tib, ax["lift"], 0.20 * up)
            P.rot(fem, UP, (0.10 * dn - 0.06 * up) * ax["sign"])
        else:
            # rear legs brace: crouch into the windup, drive on the strike
            P.rot(fem, UP, (-0.08 * up + 0.05 * dn) * ax["sign"])
            P.rot(tib, ax["lift"], -0.05 * up)
    P.apply()


def bake_action(arm_ob, P, axes, name, frames, step, fn):
    """Key `fn` over a loop of `frames` and stash it as an NLA strip."""
    if arm_ob.animation_data is None:
        arm_ob.animation_data_create()
    act = bpy.data.actions.new(name)
    act.use_fake_user = True
    arm_ob.animation_data.action = act
    # Blender 4.4+ slotted actions: assigning a fresh action may leave the slot
    # unset, and keyframe_insert then has nowhere to write.
    _ensure_slot(arm_ob.animation_data, act, arm_ob.name)

    keys = list(range(1, frames + 1, step))
    if keys[-1] != frames + 1:
        keys.append(frames + 1)
    for f in keys:
        fn(P, axes, (f - 1) / float(frames))
        P.key(f)

    track = arm_ob.animation_data.nla_tracks.new()
    track.name = name
    strip = track.strips.new(name, 1, act)
    try:
        if hasattr(strip, "action_slot") and len(act.slots):
            strip.action_slot = act.slots[0]
    except Exception as exc:                                 # pragma: no cover
        print("PY: note: could not pin NLA slot for %s (%s)" % (name, exc))
    arm_ob.animation_data.action = None
    print("PY: baked action '%s': %d keys over %d frames (%.3f s @ %d fps)"
          % (name, len(keys), frames, frames / float(FPS), FPS))
    return act, keys


def _ensure_slot(ad, act, want):
    slots = getattr(act, "slots", None)
    if slots is None:
        return                                # pre-4.4, nothing to do
    try:
        if len(slots) == 0:
            try:
                slots.new(id_type='OBJECT', name=want)
            except TypeError:
                slots.new('OBJECT', want)
        if getattr(ad, "action_slot", None) is None:
            ad.action_slot = slots[0]
    except Exception as exc:                                 # pragma: no cover
        print("PY: note: slot setup fell through (%s)" % exc)


# =============================================================================
# export + verification
# =============================================================================
def export_glb(path, **kw):
    """Filter kwargs to what this Blender's exporter actually accepts."""
    # The sky, baked in first. These carried no vertex colour at all.
    sky_light_scene(load_sky(default_sky()))
    props = set(bpy.ops.export_scene.gltf.get_rna_type().properties.keys())
    # COLOR_0 only leaves the exporter if it is asked for by name: the default
    # emits vertex colours a shader graph reads, and these materials do not.
    kw.setdefault("export_vertex_color", "ACTIVE")
    kw = {k: v for k, v in kw.items() if k in props}
    bpy.ops.export_scene.gltf(filepath=path, **kw)
    return kw


def read_glb(path):
    """-> (json document, BIN chunk bytes). 12-byte header, then chunks."""
    with open(path, "rb") as f:
        magic, ver, _total = struct.unpack("<4sII", f.read(12))
        assert magic == b"glTF", "not a glb: %s" % path
        assert ver == 2, "glTF version %d" % ver
        n, kind = struct.unpack("<II", f.read(8))
        assert kind == 0x4E4F534A, "first chunk is not JSON"
        doc = json.loads(f.read(n).decode("utf-8"))
        blob = b""
        head = f.read(8)
        if len(head) == 8:
            n2, kind2 = struct.unpack("<II", head)
            assert kind2 == 0x004E4942, "second chunk is not BIN"
            blob = f.read(n2)
        return doc, blob


_CT = {5120: ("b", 1), 5121: ("B", 1), 5122: ("h", 2),
       5123: ("H", 2), 5125: ("I", 4), 5126: ("f", 4)}
_NC = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def read_accessor(doc, blob, idx):
    acc = doc["accessors"][idx]
    ncomp = _NC[acc["type"]]
    fmt, size = _CT[acc["componentType"]]
    bv = doc["bufferViews"][acc["bufferView"]]
    base = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    stride = bv.get("byteStride") or (ncomp * size)
    spec = "<%d%s" % (ncomp, fmt)
    return [struct.unpack_from(spec, blob, base + i * stride)
            for i in range(acc["count"])]


def trs(t, r, s):
    return (Matrix.Translation(Vector(t))
            @ Quaternion((r[3], r[0], r[1], r[2])).to_matrix().to_4x4()
            @ Matrix.Diagonal(Vector((s[0], s[1], s[2], 1.0))))


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
        M = M @ Quaternion((w, x, y, z)).to_matrix().to_4x4()
    if "scale" in nd:
        M = M @ Matrix.Diagonal(Vector(nd["scale"] + [1.0]))
    return M


def audit(path, promised, bones, anims, budget):
    doc, _blob = read_glb(path)
    nodes = doc.get("nodes", [])
    names = [nd.get("name", "") for nd in nodes]
    label = os.path.basename(path)
    fails = []

    print("PY: --- %s (%d bytes) ---" % (label, os.path.getsize(path)))
    print("PY: %s nodes (%d): %s" % (label, len(names), ", ".join(n for n in names if n)))

    missing = [n for n in promised if n not in names]
    if missing:
        fails.append("promised nodes missing: %s" % missing)
    else:
        print("PY: %s node contract OK (%d/%d promised nodes present by exact name)"
              % (label, len(promised), len(promised)))

    # --- triangles ----------------------------------------------------------
    mesh_tris = {}
    for mi, mesh in enumerate(doc.get("meshes", [])):
        tot = 0
        for prim in mesh["primitives"]:
            if prim.get("mode", 4) != 4:
                fails.append("non-triangle primitive mode in mesh %d" % mi)
            if "indices" in prim:
                tot += doc["accessors"][prim["indices"]]["count"] // 3
            else:
                tot += doc["accessors"][prim["attributes"]["POSITION"]]["count"] // 3
        mesh_tris[mi] = tot
    total = 0
    for nd in nodes:
        if "mesh" in nd:
            t = mesh_tris[nd["mesh"]]
            total += t
            print("PY: %s mesh '%s' triangles = %d" % (label, nd.get("name", "?"), t))
    print("PY: %s TOTAL triangles = %d / budget %d" % (label, total, budget))
    if total > budget:
        fails.append("%d tris over budget %d" % (total, budget))

    # --- skin ---------------------------------------------------------------
    skins = doc.get("skins", [])
    if not skins:
        fails.append("no 'skins' array: the mesh is not rigged")
    else:
        joints = skins[0].get("joints", [])
        jnames = [names[j] for j in joints]
        print("PY: %s skins=%d, skin[0] joints=%d" % (label, len(skins), len(joints)))
        print("PY: %s joint names: %s" % (label, ", ".join(jnames)))
        if len(joints) != len(bones):
            fails.append("skin has %d joints, expected %d" % (len(joints), len(bones)))
        jmiss = [b for b in bones if b not in jnames]
        if jmiss:
            fails.append("bones missing from skin joints: %s" % jmiss)
        if "inverseBindMatrices" not in skins[0]:
            fails.append("skin has no inverseBindMatrices")
        else:
            ibm = doc["accessors"][skins[0]["inverseBindMatrices"]]["count"]
            print("PY: %s inverseBindMatrices count = %d" % (label, ibm))
            if ibm != len(joints):
                fails.append("ibm count %d != joint count %d" % (ibm, len(joints)))
    for mesh in doc.get("meshes", []):
        for prim in mesh["primitives"]:
            for attr in ("JOINTS_0", "WEIGHTS_0"):
                if attr not in prim["attributes"]:
                    fails.append("primitive missing %s" % attr)

    # --- animations ---------------------------------------------------------
    animations = doc.get("animations", [])
    got = [a.get("name", "") for a in animations]
    print("PY: %s animations=%d: %s" % (label, len(animations), got))
    if sorted(got) != sorted(anims):
        fails.append("animation names %s != expected %s" % (got, anims))
    for a in animations:
        targets, paths = set(), {}
        for ch in a["channels"]:
            t = ch["target"]
            if "node" in t:
                targets.add(names[t["node"]])
            paths[ch["target"]["path"]] = paths.get(ch["target"]["path"], 0) + 1
        dur = 0.0
        for s in a["samplers"]:
            acc = doc["accessors"][s["input"]]
            dur = max(dur, acc.get("max", [0.0])[0])
        print("PY: %s anim '%s': %d channels over %d nodes, paths=%s, duration=%.3f s"
              % (label, a.get("name"), len(a["channels"]), len(targets),
                 dict(sorted(paths.items())), dur))
        amiss = [b for b in bones if b not in targets]
        if amiss:
            fails.append("anim '%s' does not drive bones: %s" % (a.get("name"), amiss))
        if dur <= 0.0:
            fails.append("anim '%s' has zero duration" % a.get("name"))

    # --- bounding box (rest pose accessor min/max, walked through the tree) --
    lo, hi = [float("inf")] * 3, [float("-inf")] * 3

    def walk(idx, parent):
        nd = nodes[idx]
        M = parent @ node_matrix(nd)
        if "mesh" in nd:
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
        for c in nd.get("children", []):
            walk(c, M)

    for sc in doc.get("scenes", []):
        for r in sc.get("nodes", []):
            walk(r, Matrix.Identity(4))

    size = [hi[k] - lo[k] for k in range(3)]
    print("PY: %s bbox min (%.4f, %.4f, %.4f) max (%.4f, %.4f, %.4f) metres"
          % (label, lo[0], lo[1], lo[2], hi[0], hi[1], hi[2]))
    print("PY: %s size  width X=%.3f  height Y=%.3f  length Z=%.3f metres"
          % (label, size[0], size[1], size[2]))
    if abs(lo[1]) > 1e-4:
        fails.append("ground contact not at 0 (min Y = %.5f)" % lo[1])
    else:
        print("PY: %s ground contact OK (min Y = %.6f)" % (label, lo[1]))
    cx, cz = (lo[0] + hi[0]) * 0.5, (lo[2] + hi[2]) * 0.5
    print("PY: %s XZ centre offset = (%.4f, %.4f) metres" % (label, cx, cz))
    if max(abs(cx), abs(cz)) > 0.005:
        fails.append("not centred in XZ: offset (%.4f, %.4f)" % (cx, cz))
    for k, dim in enumerate(("width", "height", "length")):
        if abs(size[k] - INTENT[k]) > INTENT_TOL:
            fails.append("%s is %.3f m, intended %.2f +/- %.2f"
                         % (dim, size[k], INTENT[k], INTENT_TOL))
    print("PY: %s dimensions within %.2f m of intent %s OK"
          % (label, INTENT_TOL, INTENT))

    # --- materials ----------------------------------------------------------
    mats = doc.get("materials", [])
    emissive = [m.get("name", "?") for m in mats
                if any(v > 0.0 for v in m.get("emissiveFactor", [0, 0, 0]))]
    print("PY: %s materials = %s ; emissive = %s"
          % (label, [m.get("name") for m in mats], emissive))
    if not emissive:
        fails.append("no emissive material survived export")
    if doc.get("images") or doc.get("textures"):
        fails.append("textures present, this project has no texture pipeline")
    else:
        print("PY: %s no textures/images in glb OK" % label)

    return total, size, fails


# Design intent, asserted against the export so a silent geometry slip cannot
# ship. (width X, height Y, length Z) in metres, and the tolerance either way.
INTENT = (1.04, 1.00, 1.78)
INTENT_TOL = 0.06


def check_stance(pos, groups):
    """The four hooves must actually sit at four corners under the body.

    This is the check that would have caught the bug that ate an afternoon:
    box_pts dropped the y centre, so all four hooves were built on the centre
    line, inside the abdomen. Every structural assertion still passed — right
    node names, right joint count, right triangle count, a skin, three
    animations — because none of them looked at WHERE anything was. The walk
    cycle was the symptom: hooves sitting on the leg's own rotation axis
    barely move when the leg swings.
    """
    fails = []
    want = {"fl": (-1, -1), "fr": (+1, -1), "bl": (-1, +1), "br": (+1, +1)}
    for bone, idxs in sorted(groups.items()):
        key = bone[4:6]
        c = [sum(pos[i][k] for i in idxs) / len(idxs) for k in range(3)]
        sx, sz = want[key]
        print("PY: stance hoof %-14s sole centre (%.3f, %.3f, %.3f) m"
              % (bone, c[0], c[1], c[2]))
        # glTF: +X is the animal's left-vs-right axis, -Z is forward
        if abs(c[0]) < 0.25:
            fails.append("hoof %s is %.3f m off the centre line — it is tucked "
                         "under the body, not out on a leg" % (key, abs(c[0])))
        if c[0] * sx < 0:
            fails.append("hoof %s is on the wrong side (x = %.3f)" % (key, c[0]))
        if c[2] * sz < 0:
            fails.append("hoof %s is at the wrong end (z = %.3f)" % (key, c[2]))
    return fails


def silhouette(doc, blob, w=58, h=17):
    """Coarse ASCII side and top views, rasterised from the exported triangles.

    There is no display and no GPU here, so this is the only way to actually
    look at the thing. It is a diagnostic, not an assertion — but a shape this
    size either reads at a glance or it does not.
    """
    tris = []
    for mesh in doc["meshes"]:
        for prim in mesh["primitives"]:
            P = read_accessor(doc, blob, prim["attributes"]["POSITION"])
            idx = [v[0] for v in read_accessor(doc, blob, prim["indices"])]
            for k in range(0, len(idx), 3):
                tris.append((P[idx[k]], P[idx[k + 1]], P[idx[k + 2]]))

    def view(title, ax, ay, flip_y):
        lo = [min(min(t[i][a] for i in range(3)) for t in tris) for a in (ax, ay)]
        hi = [max(max(t[i][a] for i in range(3)) for t in tris) for a in (ax, ay)]
        grid = [[" "] * w for _ in range(h)]
        sx = (w - 1) / max(1e-6, hi[0] - lo[0])
        sy = (h - 1) / max(1e-6, hi[1] - lo[1])
        for t in tris:
            # barycentric sprinkle: enough samples to fill a cell-sized facet
            for i in range(6):
                for j in range(6 - i):
                    a, b = i / 5.0, j / 5.0
                    c = 1.0 - a - b
                    px = t[0][ax] * a + t[1][ax] * b + t[2][ax] * c
                    py = t[0][ay] * a + t[1][ay] * b + t[2][ay] * c
                    gx = int(round((px - lo[0]) * sx))
                    gy = int(round((py - lo[1]) * sy))
                    if flip_y:
                        gy = h - 1 - gy
                    if 0 <= gx < w and 0 <= gy < h:
                        grid[gy][gx] = "#"
        print("PY: %s  (%.2f x %.2f m)" % (title, hi[0] - lo[0], hi[1] - lo[1]))
        for row in grid:
            print("PY: |%s|" % "".join(row))

    view("SIDE view, nose to the left (glTF -Z right, +Y up)", 2, 1, True)
    view("TOP view, nose at the top (glTF -Z up, +X right)", 0, 2, False)


def _phase_of(sig):
    """Phase of the fundamental of a periodic sample list, in cycles [0,1)."""
    n = len(sig)
    re = sum(v * math.cos(TAU * i / n) for i, v in enumerate(sig))
    im = sum(v * math.sin(TAU * i / n) for i, v in enumerate(sig))
    return (math.atan2(im, re) / TAU) % 1.0


def verify_motion(path):
    """Re-derive the animation from the glb alone and check it actually moves.

    Structure checks (a skins array exists, an animations array exists) do not
    prove the rig works — a rig can export perfectly and still be frozen, or
    have all four legs stepping in unison. So: walk the node hierarchy applying
    the sampled TRS, skin the ground-contact and head vertices by hand with the
    glTF formula, and measure the trajectories that come out.
    """
    doc, blob = read_glb(path)
    nodes = doc["nodes"]
    names = [nd.get("name", "") for nd in nodes]
    fails = []

    parent = {}
    for i, nd in enumerate(nodes):
        for c in nd.get("children", []):
            parent[c] = i
    roots = [i for i in range(len(nodes)) if i not in parent]

    def local_static(i):
        nd = nodes[i]
        return trs(nd.get("translation", [0, 0, 0]),
                   nd.get("rotation", [0, 0, 0, 1]),
                   nd.get("scale", [1, 1, 1]))

    skin_d = doc["skins"][0]
    joints = skin_d["joints"]
    ibm = read_accessor(doc, blob, skin_d["inverseBindMatrices"])
    IBM = [Matrix([[m[0], m[4], m[8], m[12]], [m[1], m[5], m[9], m[13]],
                   [m[2], m[6], m[10], m[14]], [m[3], m[7], m[11], m[15]]])
           for m in ibm]

    mesh = doc["meshes"][0]
    pos, jnt, wgt = [], [], []
    for prim in mesh["primitives"]:
        pos += read_accessor(doc, blob, prim["attributes"]["POSITION"])
        jnt += read_accessor(doc, blob, prim["attributes"]["JOINTS_0"])
        wgt += read_accessor(doc, blob, prim["attributes"]["WEIGHTS_0"])

    bad = [i for i, w in enumerate(wgt) if abs(sum(w) - 1.0) > 1e-3]
    print("PY: skin weights: %d vertices, %d with |sum-1| > 1e-3" % (len(wgt), len(bad)))
    if bad:
        fails.append("%d vertices have non-normalised skin weights" % len(bad))

    def dominant(i):
        return names[joints[max(zip(wgt[i], jnt[i]))[1]]]

    # Hoof soles = the vertices sitting exactly on the ground plane in rest.
    # The exporter splits a vertex once per distinct normal, so one sole corner
    # can come back as three records — count distinct POSITIONS, which is what
    # "four corners per hoof" actually means.
    soles = [i for i, p in enumerate(pos) if abs(p[1]) < 1e-6]
    groups, corners = {}, {}
    for i in soles:
        b = dominant(i)
        groups.setdefault(b, []).append(i)
        corners.setdefault(b, set()).add(tuple(round(c, 6) for c in pos[i]))
    print("PY: ground-contact vertex records: %d in %d groups: %s"
          % (len(soles), len(groups),
             ", ".join("%s x%d (%d distinct positions)" % (k, len(v), len(corners[k]))
                       for k, v in sorted(groups.items()))))
    want_feet = sorted("leg_%s_tibia" % k for k in LEG_PHASE)
    if sorted(groups) != want_feet:
        fails.append("ground contacts driven by %s, expected %s"
                     % (sorted(groups), want_feet))
    ncorner = sum(len(v) for v in corners.values())
    if ncorner != 16:
        fails.append("expected 16 distinct hoof-sole corners on the ground plane, "
                     "found %d" % ncorner)

    fails += check_stance(pos, groups)

    heads = [i for i in range(len(pos)) if dominant(i) == "head"]
    # The animal leads with the shield: the forward-most geometry must be on
    # the head bone, not a knee or a brow that happens to stick out further.
    fwd = min(range(len(pos)), key=lambda i: pos[i][2])
    print("PY: forward-most vertex at z = %.3f m, driven by '%s'"
          % (pos[fwd][2], dominant(fwd)))
    if dominant(fwd) != "head":
        fails.append("forward-most geometry is driven by '%s', not the head "
                     "shield" % dominant(fwd))
    print("PY: head-shield vertices (dominant bone 'head'): %d" % len(heads))
    if len(heads) < 20:
        fails.append("only %d head-driven vertices, the shield is not on the head bone"
                     % len(heads))

    for anim in doc["animations"]:
        aname = anim.get("name")
        times = None
        chans = {}
        for ch in anim["channels"]:
            smp = anim["samplers"][ch["sampler"]]
            t = [v[0] for v in read_accessor(doc, blob, smp["input"])]
            if times is None:
                times = t
            elif t != times:
                fails.append("anim '%s': channels do not share sample times" % aname)
            chans[(ch["target"]["node"], ch["target"]["path"])] = \
                read_accessor(doc, blob, smp["output"])

        def world_at(k):
            W = {}

            def walk(i, M):
                nd = nodes[i]
                tr = chans.get((i, "translation"))
                ro = chans.get((i, "rotation"))
                sc = chans.get((i, "scale"))
                if tr is None and ro is None and sc is None:
                    L = local_static(i)
                else:
                    L = trs(tr[k] if tr else nd.get("translation", [0, 0, 0]),
                            ro[k] if ro else nd.get("rotation", [0, 0, 0, 1]),
                            sc[k] if sc else nd.get("scale", [1, 1, 1]))
                M = M @ L
                W[i] = M
                for c in nd.get("children", []):
                    walk(c, M)

            for r in roots:
                walk(r, Matrix.Identity(4))
            return W

        frames = [world_at(k) for k in range(len(times))]

        def skinned(W, vi):
            out = Vector((0.0, 0.0, 0.0))
            p = Vector(pos[vi])
            for w, j in zip(wgt[vi], jnt[vi]):
                if w > 0.0:
                    out += (W[joints[j]] @ IBM[j] @ p) * w
            return out

        def centroid(W, idxs):
            acc = Vector((0.0, 0.0, 0.0))
            for i in idxs:
                acc += skinned(W, i)
            return acc / len(idxs)

        tracks = {b: [centroid(W, idxs) for W in frames]
                  for b, idxs in groups.items()}
        head_tr = [centroid(W, heads) for W in frames]

        # loop closure: the last key must reproduce the first
        worst = max((tracks[n][0] - tracks[n][-1]).length for n in tracks)
        worst = max(worst, (head_tr[0] - head_tr[-1]).length)
        print("PY: anim '%s': %d samples, %.3f..%.3f s, loop closure error %.6f m"
              % (aname, len(times), times[0], times[-1], worst))
        if worst > 1e-4:
            fails.append("anim '%s' does not loop (drift %.5f m)" % (aname, worst))

        phase = {}
        for n in sorted(tracks):
            ys = [p.y for p in tracks[n]]
            zs = [p.z for p in tracks[n]]
            xs = [p.x for p in tracks[n]]
            lift = max(ys) - min(ys)
            stride = max(zs) - min(zs)
            key = n[4:6]
            phase[key] = _phase_of(ys[:-1])
            print("PY: anim '%s' hoof %-14s lift %.4f m, fore/aft travel %.4f m, "
                  "lateral %.4f m, min height %.4f m, phase %.3f cyc"
                  % (aname, n, lift, stride, max(xs) - min(xs), min(ys), phase[key]))
            if aname == "walk":
                if lift < 0.040:
                    fails.append("walk: hoof %s lifts only %.4f m, not a readable step"
                                 % (n, lift))
                if stride < 0.120:
                    fails.append("walk: hoof %s travels only %.4f m fore/aft" % (n, stride))
                if min(ys) > 0.015:
                    fails.append("walk: hoof %s never plants (min height %.4f m)"
                                 % (n, min(ys)))
            elif aname == "idle":
                # 30 mm on a 1.0 m tall animal is 3% of its height — below the
                # size of one pixel at the RTS camera's working distance. The
                # point of the check is that the idle is a weight shift, not a
                # step; the sink check is the one that catches a broken idle.
                if lift > 0.030:
                    fails.append("idle: hoof %s lifts %.4f m, too busy for an idle"
                                 % (n, lift))
                if min(ys) < -0.015:
                    fails.append("idle: hoof %s sinks %.4f m through the ground"
                                 % (n, min(ys)))
            else:                                    # slam
                if min(ys) < -0.030:
                    fails.append("slam: hoof %s sinks %.4f m through the ground"
                                 % (n, min(ys)))

        if aname == "walk":
            # Lateral-sequence four-beat walk: each hoof in WALK_ORDER lags the
            # previous one by a quarter cycle. Measured from the fundamental of
            # the height signal, so it is robust to which exact sample peaks.
            print("PY: walk beat order %s phases %s"
                  % (list(WALK_ORDER),
                     ["%.3f" % phase[k] for k in WALK_ORDER]))
            # A signal DELAYED by p has its fundamental phase shifted by -p,
            # so the later hoof in the beat order has the LOWER measured phase.
            for a, b in zip(WALK_ORDER, WALK_ORDER[1:] + WALK_ORDER[:1]):
                dp = (phase[a] - phase[b]) % 1.0
                print("PY: walk phase %s -> %s = %.3f cycle (want 0.250)" % (a, b, dp))
                if abs(dp - 0.25) > 0.03:
                    fails.append("walk: %s -> %s phase is %.3f, not a quarter cycle"
                                 % (a, b, dp))
            # The load-bearing claim about this gait: a heavy quadruped never
            # has fewer than three hooves down. Measured from the glb, not
            # asserted from the phase table that produced it.
            down = []
            for k in range(len(times) - 1):
                down.append(sum(1 for n in tracks if tracks[n][k].y < 0.020))
            print("PY: walk hooves on the ground per sample: %s" % down)
            print("PY: walk minimum hooves down = %d (want >= 3)" % min(down))
            if min(down) < 3:
                fails.append("walk: only %d hooves down at once, that is a trot"
                             % min(down))

            # stance drift: how far a planted hoof floats while it should be down
            for n in sorted(tracks):
                key = n[4:6]
                ys = [p.y for p in tracks[n]]
                st = [ys[k] for k in range(len(times) - 1)
                      if ((k / float(len(times) - 1)) + LEG_PHASE[key]) % 1.0 < STANCE]
                print("PY: walk hoof %-14s stance-phase height max %.4f m over %d samples"
                      % (n, max(st), len(st)))
                if max(st) > 0.030:
                    fails.append("walk: hoof %s floats %.4f m while planted" % (n, max(st)))

        if aname == "slam":
            ys = [p.y for p in head_tr]
            zs = [p.z for p in head_tr]
            rest, top, bot = ys[0], max(ys), min(ys)
            print("PY: slam shield centroid height: rest %.4f  peak %.4f  floor %.4f m"
                  % (rest, top, bot))
            print("PY: slam shield rise %.4f m, drive %.4f m, total travel %.4f m"
                  % (top - rest, rest - bot, top - bot))
            print("PY: slam shield forward (glTF -Z) reach: %.4f .. %.4f m"
                  % (-max(zs), -min(zs)))
            if top - rest < 0.10:
                fails.append("slam: shield only rears %.4f m" % (top - rest))
            if rest - bot < 0.20:
                fails.append("slam: shield only drives down %.4f m" % (rest - bot))
            if bot < 0.0:
                fails.append("slam: shield centroid goes %.4f m below ground" % bot)
            # the strike must be faster than the recovery, or it reads as a nod
            drop = min(range(len(ys)), key=lambda k: ys[k])
            rise = max(range(len(ys)), key=lambda k: ys[k])
            print("PY: slam windup peak at sample %d/%d, impact at sample %d/%d"
                  % (rise, len(ys) - 1, drop, len(ys) - 1))
            if not rise < drop:
                fails.append("slam: shield does not rear before it drives down")
    return fails


# =============================================================================
def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.fps = FPS
    scene.frame_start, scene.frame_end = 1, 49
    mats = make_materials()

    # --- mesh ---------------------------------------------------------------
    b = build_mesh()
    xs = [v[0] for v in b.v]
    ys = [v[1] for v in b.v]
    zs = [v[2] for v in b.v]
    # Origin contract: hoof soles at z = 0, centred in Blender XY. The fore/aft
    # centring matters — the shield reaches further forward than the abdomen
    # reaches back, so the authored origin is not the bbox centre.
    shift = (-(min(xs) + max(xs)) * 0.5,
             -(min(ys) + max(ys)) * 0.5,
             -min(zs))
    print("PY: raw bbox x %.4f..%.4f  y %.4f..%.4f  z %.4f..%.4f m"
          % (min(xs), max(xs), min(ys), max(ys), min(zs), max(zs)))
    print("PY: origin shift applied (%.6f, %.6f, %.6f) m" % shift)
    b.v = [(x + shift[0], y + shift[1], z + shift[2]) for (x, y, z) in b.v]

    me = bpy.data.meshes.new("breacher_body_mesh")
    me.from_pydata(b.v, [], b.f)
    me.update()
    for m in mats:
        me.materials.append(m)
    for i, mi in enumerate(b.m):
        me.polygons[i].material_index = mi
    mesh_ob = bpy.data.objects.new("breacher_body", me)
    bpy.context.collection.objects.link(mesh_ob)
    print("PY: mesh built: %d verts, %d tris (budget %d)"
          % (len(b.v), b.tris, TRI_BUDGET))
    if b.tris > TRI_BUDGET:
        raise SystemExit("FAIL: %d tris over budget before export" % b.tris)

    # consistent outward normals: the body is a union of closed convex shells
    # that interpenetrate, so recalc rather than trusting every hand winding
    import bmesh
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me)
    bm.free()
    me.update()

    # --- rig ----------------------------------------------------------------
    arm_ob = build_armature("AlienBreacher", shift)
    bones = [d[0] for d in bone_defs()]
    print("PY: armature '%s' has %d bones: %s"
          % (arm_ob.name, len(arm_ob.data.bones), ", ".join(bones)))
    if len(arm_ob.data.bones) != 11:
        raise SystemExit("FAIL: expected 11 bones, built %d" % len(arm_ob.data.bones))
    nb = skin(mesh_ob, arm_ob, b.w)
    infl = max(len(w) for w in b.w)
    print("PY: skinned: %d vertex groups, %d weight batches, max %d influences/vertex"
          % (len(mesh_ob.vertex_groups), nb, infl))
    if infl > 4:
        raise SystemExit("FAIL: %d influences/vertex exceeds glTF's 4" % infl)

    # --- animation ----------------------------------------------------------
    axes = leg_axes(arm_ob)
    for k in sorted(axes):
        ax = axes[k]
        print("PY: leg %s lift axis (%.3f, %.3f, %.3f) swing sign %+d"
              % (k, ax["lift"].x, ax["lift"].y, ax["lift"].z, int(ax["sign"])))
    pivot = rear_ground_pivot(arm_ob)
    print("PY: slam rear-up pivot (Blender) = (%.4f, %.4f, %.4f) m"
          % (pivot.x, pivot.y, pivot.z))

    P = Poser(arm_ob)
    bake_action(arm_ob, P, axes, "idle", 48, 4, pose_idle)
    bake_action(arm_ob, P, axes, "walk", 24, 1, pose_walk)
    bake_action(arm_ob, P, axes, "slam", 18, 1,
                lambda p, a, t: pose_slam(p, a, t, pivot))
    P.clear()
    P.apply()                       # leave the rig at rest for the bind pose

    # --- export -------------------------------------------------------------
    path = os.path.join(OUT, "alien_breacher.glb")
    used = export_glb(
        path,
        export_format='GLB',
        export_apply=False,
        export_yup=True,
        export_materials='EXPORT',
        use_selection=False,
        export_skins=True,
        export_def_bones=False,
        export_rest_position_armature=True,
        export_animations=True,
        export_animation_mode='ACTIONS',
        export_frame_range=False,
        export_force_sampling=True,
        export_optimize_animation_size=False,
        export_bake_animation=True,
        export_anim_slide_to_zero=True,
        export_nla_strips=True,
        export_extras=False,
        export_cameras=False,
        export_lights=False,
    )
    print("PY: exporter options used: %s" % dict(sorted(used.items())))
    print("PY: exported %s (%d bytes)" % (path, os.path.getsize(path)))

    promised = ["AlienBreacher", "breacher_body"] + bones
    total, size, fails = audit(path, promised, bones,
                               ["idle", "walk", "slam"], TRI_BUDGET)
    fails += verify_motion(path)
    doc, blob = read_glb(path)
    silhouette(doc, blob)

    if fails:
        for f in fails:
            print("PY: FAIL %s" % f)
        raise SystemExit("FAIL: %d assertion(s) failed" % len(fails))
    print("PY: ===== summary =====")
    print("PY: alien_breacher %d tris, %.3f x %.3f x %.3f m (width, height, length)"
          % (total, size[0], size[1], size[2]))
    print("PY: ALL CHECKS PASSED")


main()
