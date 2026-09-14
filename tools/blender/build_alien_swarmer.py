"""SENTINEL — procedural alien swarmer (rigged + animated).

The cheap fast alien: ~0.8 m nose-to-tail, low slung, six legs, narrow wedge
carapace, mandibles. Built from explicit triangle lists so the triangle count
is known exactly before export and can be asserted against the exported glTF.

    ~/.cache/blender-venv/bin/python tools/blender/build_alien_swarmer.py [out_dir]

Conventions (project asset pass):
  * metres, Z-up in Blender; the glTF exporter converts to Y-up for Godot
  * origin at the ground contact point (claw tips sit at z = 0), centred in XY
  * solid colours + emission only, no UVs, no textures
  * fully deterministic: no random calls anywhere, no timestamps

Authoring space
  Everything below is authored with "forward" = +X because that keeps the
  profile lists readable as (forward, up) pairs. Godot's forward is -Z and the
  glTF exporter maps Blender (x, y, z) -> glTF (x, z, -y), so Blender +Y is the
  axis that lands on glTF -Z. ORIENT is a quarter turn taking the authored +X
  forward onto Blender +Y, baked into vertices and bone rest positions rather
  than left on a node transform, so the exported nodes keep identity rotations.
  Left-side parts are authored once at +Y and emitted twice; the mirror matrix
  has a negative determinant so _emit flips the winding to keep normals out.

Rig
  root -> spine_01 (thorax) -> spine_02 (head)
       -> spine_01 -> abdomen
       -> spine_01 -> leg_{l,r}{1,2,3}_femur -> ..._tibia
  16 bones. Two baked actions, 'idle' and 'run'. 'run' is an alternating
  tripod: {l1, r2, l3} steps half a cycle out of phase with {r1, l2, r3},
  which is the correct hexapod gait and the thing that makes a scuttle read.

Pose maths
  Poses are authored as world-space rotations about a world axis through the
  bone head, then converted to the bone-local basis Blender wants with
      matrix_basis = rest_local^-1 @ W @ rest_local
  which follows from pose = pose_parent @ rest_parent^-1 @ rest @ basis. Doing
  it this way means a leg's swing axis is "world up" and its lift axis is
  "horizontal, perpendicular to the leg" — both readable — instead of whatever
  the bone roll happened to come out as.
"""
import bpy, sys, os, math, cmath, struct, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mathutils import Matrix, Vector, Quaternion

from _bl import script_args  # noqa: F401  (kept so both front ends work)

argv = script_args()
OUT = os.path.abspath(argv[0] if argv else "models")
os.makedirs(OUT, exist_ok=True)

TRI_BUDGET = 900                 # hard limit for one alien
EXPECT_SHELLS = 56               # one closed shell per authored part
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


def _shift_y(pts, dy):
    return [(p[0], p[1] + dy, p[2]) for p in pts]


def box_pts(c, s):
    """Box centred on c. seg_pts is symmetric about y = 0, so c[1] has to be
    applied afterwards -- forgetting it buries every off-centre box inside the
    body, which is invisible in a triangle count and in a bounding box."""
    hx, hy, hz = s[0] * 0.5, s[1] * 0.5, s[2] * 0.5
    return _shift_y(seg_pts(c[0] - hx, c[0] + hx, hy, hy,
                            c[2] - hz, c[2] + hz, c[2] - hz, c[2] + hz), c[1])


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
# SWARMER — geometry
# =============================================================================
# Hip / knee / foot for the three LEFT legs. Right legs are the Y mirror.
# Knees ride above the body line (insect posture), feet plant at z = 0.
#
# Fore/aft foot SPLAY is deliberately modest. Protraction here is a yaw about
# the vertical through the hip, and the foot then travels perpendicular to the
# hip->foot radius: a leg reaching far forward or far back sweeps mostly
# SIDEWAYS under that yaw. The first layout splayed to x = +0.378 / -0.295 and
# measured 0.146 m of lateral paddle against 0.100 m of stride -- legs rowing,
# not scuttling. Pulling the feet toward the lateral line trades a little
# sprawl for stride that actually points where the animal is going: now
# 0.03-0.08 m lateral against ~0.10 m stride, even across all six legs.
LEGS = {
    "l1": ((0.215,  0.078, 0.150), (0.300,  0.236, 0.230), (0.312,  0.220, 0.0)),
    "l2": ((0.060,  0.088, 0.150), (0.100,  0.258, 0.230), (0.108,  0.242, 0.0)),
    "l3": ((-0.100, 0.082, 0.150), (-0.150, 0.252, 0.230), (-0.165, 0.240, 0.0)),
}
SIDES = ((1, "l"), (-1, "r"))
CLAW_Z = 0.040                       # ankle height; claw spike runs down to 0

FEM_R0, FEM_R1 = 0.024, 0.018
TIB_R0, TIB_R1 = 0.018, 0.011
CLAW_R = 0.013


def clamp01(x):
    return 0.0 if x < 0.0 else (1.0 if x > 1.0 else x)


def body_w(p):
    """Smooth abdomen / thorax / head weights from the authored x coordinate.

    Blend bands rather than per-part rigid assignment, so the waist and neck
    bend instead of shearing when the spine sways.
    """
    x = p[0]
    wa = clamp01((0.050 - x) / 0.140)        # 1 behind x=-0.09, 0 ahead of 0.05
    wh = clamp01((x - 0.235) / 0.090)        # 0 behind x=0.235, 1 ahead of 0.325
    ws = max(0.0, 1.0 - wa - wh)
    tot = wa + wh + ws
    d = {}
    if wa > 1e-6:
        d["abdomen"] = wa / tot
    if ws > 1e-6:
        d["spine_01"] = ws / tot
    if wh > 1e-6:
        d["spine_02"] = wh / tot
    return d


def ankle_of(knee, foot):
    k, f = Vector(knee), Vector(foot)
    return k.lerp(f, (k.z - CLAW_Z) / (k.z - f.z))


def build_body(b):
    """Thorax, head, abdomen, belly. 12 tris per hexahedron."""
    W = body_w
    # --- thorax ------------------------------------------------------------
    b.seg(CHITIN, (0.020, 0.150, 0.100, 0.094, 0.126, 0.234, 0.130, 0.240), W)
    b.seg(CHITIN, (0.146, 0.250, 0.094, 0.068, 0.130, 0.240, 0.138, 0.222), W)
    b.seg(CHITIN, (0.000, 0.245, 0.062, 0.028, 0.230, 0.272, 0.226, 0.244), W)  # keel
    b.seg(FLESH,  (-0.030, 0.030, 0.098, 0.100, 0.124, 0.236, 0.125, 0.235), W)  # waist
    b.seg(FLESH,  (-0.290, 0.230, 0.072, 0.068, 0.120, 0.144, 0.122, 0.150), W)  # belly

    # --- abdomen: four tapering chitin segments + overlapping dorsal plates --
    b.seg(CHITIN, (-0.020, -0.120, 0.100, 0.106, 0.124, 0.236, 0.118, 0.244), W)
    b.seg(CHITIN, (-0.116, -0.220, 0.106, 0.092, 0.118, 0.244, 0.124, 0.232), W)
    b.seg(CHITIN, (-0.216, -0.310, 0.092, 0.064, 0.124, 0.232, 0.138, 0.206), W)
    b.seg(CHITIN, (-0.306, -0.400, 0.064, 0.016, 0.138, 0.206, 0.164, 0.184), W)
    b.seg(CHITIN, (-0.040, -0.135, 0.108, 0.110, 0.228, 0.252, 0.234, 0.258), W)
    b.seg(CHITIN, (-0.150, -0.240, 0.104, 0.088, 0.230, 0.254, 0.222, 0.242), W)
    b.seg(CHITIN, (-0.250, -0.330, 0.084, 0.056, 0.220, 0.242, 0.208, 0.226), W)
    b.seg(GLOW,   (-0.060, -0.300, 0.014, 0.010, 0.246, 0.256, 0.228, 0.238), W)

    # --- head --------------------------------------------------------------
    b.seg(FLESH,  (0.235, 0.265, 0.068, 0.062, 0.134, 0.226, 0.136, 0.216), W)  # neck
    b.seg(CHITIN, (0.255, 0.355, 0.060, 0.042, 0.138, 0.212, 0.148, 0.184), W)
    b.seg(CHITIN, (0.265, 0.360, 0.042, 0.020, 0.206, 0.236, 0.180, 0.198),
          {"spine_02": 1.0})


def build_sided(b, s, side, M):
    """Everything that exists once per side. Authored at +Y, mirrored for -Y."""
    hd = {"spine_02": 1.0}
    W = body_w

    # --- shoulder flare over the leg row ------------------------------------
    b.hexa(CHITIN, [(0.010, 0.086, 0.196), (0.010, 0.158, 0.164),
                    (0.010, 0.154, 0.182), (0.010, 0.084, 0.222),
                    (0.245, 0.064, 0.198), (0.245, 0.118, 0.172),
                    (0.245, 0.115, 0.188), (0.245, 0.063, 0.220)], W, M)
    # swept-back dorsal spine flanking the keel
    b.spike(CHITIN, (0.130, 0.048, 0.246), (0.040, 0.090, 0.268), 0.012, 3, W, M)
    # flank glow vent + spiracle
    b.box(GLOW, (-0.165, 0.104, 0.176), (0.150, 0.014, 0.026), W, M)
    b.box(FLESH, (-0.075, 0.103, 0.150), (0.030, 0.016, 0.028), W, M)

    # --- head: eye pod, mandible, antenna -----------------------------------
    b.hexa(GLOW, [(0.300, 0.038, 0.176), (0.300, 0.060, 0.182),
                  (0.300, 0.058, 0.204), (0.300, 0.036, 0.200),
                  (0.345, 0.030, 0.170), (0.345, 0.046, 0.176),
                  (0.345, 0.045, 0.192), (0.345, 0.029, 0.188)], hd, M)
    b.tube(CHITIN, (0.330, 0.042, 0.152), (0.380, 0.055, 0.146),
           0.018, 0.011, 4, hd, hd, M)
    b.spike(CHITIN, (0.380, 0.055, 0.146), (0.400, 0.026, 0.140), 0.011, 3, hd, M)
    b.spike(CHITIN, (0.330, 0.030, 0.212), (0.215, 0.082, 0.262), 0.009, 3, hd, M)

    # --- legs ---------------------------------------------------------------
    for idx in (1, 2, 3):
        hip, knee, foot = LEGS["l%d" % idx]
        fem = "leg_%s%d_femur" % (side, idx)
        tib = "leg_%s%d_tibia" % (side, idx)
        ankle = ankle_of(knee, foot)

        b.box(FLESH, (hip[0], hip[1] + 0.012, hip[2]), (0.055, 0.045, 0.050),
              {"spine_01": 0.45, fem: 0.55}, M)
        b.tube(CHITIN, hip, knee, FEM_R0, FEM_R1, 4,
               {"spine_01": 0.20, fem: 0.80}, {fem: 0.70, tib: 0.30}, M)
        b.tube(CHITIN, knee, ankle, TIB_R0, TIB_R1, 4,
               {fem: 0.25, tib: 0.75}, {tib: 1.0}, M)
        b.spike(CHITIN, ankle, foot, CLAW_R, 3, {tib: 1.0}, M)


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
        ("root",     None,       (0.000, 0.0, 0.000), (0.000, 0.0, 0.100), False),
        ("spine_01", "root",     (0.020, 0.0, 0.176), (0.240, 0.0, 0.180), False),
        ("spine_02", "spine_01", (0.240, 0.0, 0.180), (0.380, 0.0, 0.168), True),
        ("abdomen",  "spine_01", (0.020, 0.0, 0.176), (-0.340, 0.0, 0.182), False),
    ]
    for s, side in SIDES:
        for idx in (1, 2, 3):
            hip, knee, foot = LEGS["l%d" % idx]
            mir = (lambda p: (p[0], p[1] * s, p[2]))
            fem = "leg_%s%d_femur" % (side, idx)
            tib = "leg_%s%d_tibia" % (side, idx)
            defs.append((fem, "spine_01", mir(hip), mir(knee), False))
            defs.append((tib, fem, mir(knee), mir(foot), True))
    return defs


def build_armature(name, z_shift):
    arm = bpy.data.armatures.new("swarmer_rig")
    ob = bpy.data.objects.new(name, arm)
    bpy.context.collection.objects.link(ob)
    bpy.context.view_layer.objects.active = ob
    ob.select_set(True)
    bpy.ops.object.mode_set(mode='EDIT')

    Z = Matrix.Translation(Vector((0.0, 0.0, z_shift)))
    for bname, parent, head, tail, conn in bone_defs():
        eb = arm.edit_bones.new(bname)
        eb.head = Z @ (ORIENT @ Vector(head))
        eb.tail = Z @ (ORIENT @ Vector(tail))
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

    def parent_extra(self, name):
        """Accumulated world transform this bone inherits from its parents."""
        chain = []
        b = self.ob.data.bones[name].parent
        while b:
            chain.append(b.name)
            b = b.parent
        M = Matrix.Identity(4)
        for n in reversed(chain):
            M = M @ self.W[n]
        return M

    def plant(self, names):
        """Cancel inherited body motion on these bones, exactly.

        pose chain composes as W(bone) = W(parent chain) @ W(bone), so
        pre-multiplying by the inverse of the parent chain leaves the limb
        exactly where it was. Used by the idle so the body can breathe with
        all six feet nailed to the ground instead of the whole animal
        bouncing on stilts. Call it last, after every other pose call.
        """
        for n in names:
            self.W[n] = self.parent_extra(n).inverted() @ self.W[n]

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
    angle raises the foot.  swing sign = the sign of a world-Z rotation that
    carries the foot FORWARD, which differs left vs right and is easy to get
    backwards by hand.
    """
    out = {}
    for s, side in SIDES:
        for idx in (1, 2, 3):
            key = "%s%d" % (side, idx)
            fem = arm_ob.data.bones["leg_%s_femur" % key]
            tib = arm_ob.data.bones["leg_%s_tibia" % key]
            d = (tib.tail_local - fem.head_local)
            dh = Vector((d.x, d.y, 0.0)).normalized()
            lift = dh.cross(UP).normalized()
            sign = 1.0 if UP.cross(dh).dot(FWD) > 0.0 else -1.0
            out[key] = {"lift": lift, "sign": sign}
    return out


# =============================================================================
# animation
# =============================================================================
# alternating tripod: {l1, r2, l3} half a cycle out of phase with {r1, l2, r3}
LEG_PHASE = {"l1": 0.0, "r2": 0.0, "l3": 0.0,
             "r1": 0.5, "l2": 0.5, "r3": 0.5}

# Tuned against the measured foot trajectories printed by verify_motion(),
# not by eye — there is no display here. Targets: step height 15-25% of body
# height (0.272 m), fore/aft stride ~0.13 m, lateral foot swing small. The
# tibia sits near-vertical, so flexing it mostly throws the foot SIDEWAYS
# rather than up; 0.30 rad measured 0.165 m of lateral paddle, which read as
# rowing rather than scuttling. Clearance comes from the femur instead.
SWING = 0.34        # rad, fore/aft femur sweep either side of neutral
FEM_LIFT = 0.22     # rad, peak femur lift during the swing phase
TIB_FLEX = 0.08     # rad, peak tibia fold during the swing phase
RUN_BOB = 0.008     # m, body rise/fall (twice per gait cycle)
RUN_FRAMES = 10     # 10 frames @ 24 fps = 0.417 s per gait cycle


def smoothstep(f):
    return f * f * (3.0 - 2.0 * f)


def gait(u):
    """u in [0,1). -> (protraction, lift, flex).

    Stance (u < 0.5): foot planted, sweeping back at constant speed.
    Swing  (u >= 0.5): foot lifted, returning forward on a smoothstep.
    The velocity discontinuity at the ends is the foot plant and the lift-off;
    it is meant to be there.
    """
    if u < 0.5:
        f = u / 0.5
        return SWING * (1.0 - 2.0 * f), 0.0, 0.0
    f = (u - 0.5) / 0.5
    return (SWING * (2.0 * smoothstep(f) - 1.0),
            FEM_LIFT * math.sin(math.pi * f),
            math.sin(math.pi * f))


def pose_run(P, axes, t):
    P.clear()
    w = TAU * t
    # Bob is non-negative and peaks at each tripod's mid-stance, so the body
    # rises off the push instead of driving planted feet through the floor.
    P.move("root", (0.0, 0.0, RUN_BOB * 0.5 * (1.0 - math.cos(2.0 * w))))
    P.rot("root", UP, 0.022 * math.sin(w))
    # Roll stays small: it lifts one side's feet and drops the other's, which
    # at 0.045 rad pulled the two halves of a tripod 43 deg out of step.
    P.rot("root", FWD, 0.008 * math.cos(w))
    P.rot("abdomen", UP, -0.130 * math.sin(w))
    P.rot("abdomen", LAT, 0.050 * math.sin(2.0 * w))
    P.rot("spine_02", UP, 0.080 * math.sin(w))
    P.rot("spine_02", LAT, -0.050 * math.sin(2.0 * w))
    for key, ax in axes.items():
        pro, lz, flex = gait((t + LEG_PHASE[key]) % 1.0)
        fem, tib = "leg_%s_femur" % key, "leg_%s_tibia" % key
        P.rot(fem, ax["lift"], lz)              # lift first, in the rest frame
        P.rot(fem, UP, pro * ax["sign"])        # then swing about true vertical
        P.rot(tib, ax["lift"], TIB_FLEX * flex)
    P.apply()


def pose_idle(P, axes, t):
    """Standing idle: the body breathes, the six feet do not leave the ground.

    The legs hang off spine_01, so any thorax motion drags the feet with it —
    the first pass had feet floating 30 mm, which reads as hovering. plant()
    cancels that inheritance exactly, leaving only the deliberate twitch.
    """
    P.clear()
    w = TAU * t
    P.move("root", (0.0, 0.0, 0.006 * math.sin(w)))
    P.rot("root", LAT, 0.020 * math.sin(w))
    P.rot("root", FWD, 0.010 * math.sin(2.0 * w))
    P.rot("abdomen", LAT, 0.065 * math.sin(w + 0.7))
    P.rot("abdomen", UP, 0.040 * math.sin(2.0 * w))
    P.rot("spine_02", UP, 0.080 * math.sin(w))
    P.rot("spine_02", LAT, -0.050 * math.sin(2.0 * w + 1.1))
    for key, ax in axes.items():
        a = w + LEG_PHASE[key] * TAU
        fem, tib = "leg_%s_femur" % key, "leg_%s_tibia" % key
        # lift-only (never negative) so an idle foot rises off the ground a
        # few mm and settles back, rather than sinking through it
        P.rot(fem, ax["lift"], 0.013 * (0.5 - 0.5 * math.cos(a)))
        P.rot(tib, ax["lift"], 0.012 * (0.5 - 0.5 * math.cos(a + 0.9)))
    P.plant(["leg_%s_femur" % k for k in axes])
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
    props = set(bpy.ops.export_scene.gltf.get_rna_type().properties.keys())
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




def verify_solids(path):
    """Prove the mesh is a union of CLOSED, OUTWARD-facing shells.

    With no display, an inside-out part is otherwise invisible until it reaches
    a device and renders as a hole. Each authored part is one closed shell, so:
    weld by position (the exporter splits vertices per face for flat shading),
    group into connected components, and for each one require every directed
    edge to have exactly one opposite (closed, consistently wound) and the
    signed volume to be positive (wound outward, not inward).
    """
    doc, blob = read_glb(path)
    fails = []
    tris = []
    for prim in doc["meshes"][0]["primitives"]:
        pos = read_accessor(doc, blob, prim["attributes"]["POSITION"])
        idx = [v[0] for v in read_accessor(doc, blob, prim["indices"])]
        for k in range(0, len(idx), 3):
            tris.append(tuple(pos[idx[k + j]] for j in range(3)))

    vid = {}
    for t in tris:
        for q in t:
            vid.setdefault(tuple(round(c, 6) for c in q), len(vid))

    def cid(q):
        return vid[tuple(round(c, 6) for c in q)]

    T = [tuple(cid(q) for q in t) for t in tris]
    par = list(range(len(vid)))

    def find(a):
        while par[a] != a:
            par[a] = par[par[a]]
            a = par[a]
        return a

    for a, b, c in T:
        for x in (b, c):
            ra, rx = find(a), find(x)
            if ra != rx:
                par[rx] = ra

    shells = {}
    for i, t in enumerate(T):
        shells.setdefault(find(t[0]), []).append(i)

    open_shells, inverted, vols = 0, 0, []
    for _, members in shells.items():
        edges = set()
        dup = False
        for i in members:
            a, b, c = T[i]
            for e in ((a, b), (b, c), (c, a)):
                if e in edges:
                    dup = True
                edges.add(e)
        if dup or any((b, a) not in edges for (a, b) in edges):
            open_shells += 1
        vol = 0.0
        for i in members:
            v0, v1, v2 = (Vector(q) for q in tris[i])
            vol += v0.dot(v1.cross(v2))
        vol /= 6.0
        vols.append(vol)
        if vol <= 0.0:
            inverted += 1

    print("PY: solid check: %d welded verts, %d shells, total enclosed volume "
          "%.6f m^3, smallest shell %.8f m^3"
          % (len(vid), len(shells), sum(vols), min(vols)))
    if len(shells) != EXPECT_SHELLS:
        fails.append("%d shells, expected %d -- parts are sharing vertices, "
                     "which means two of them are coincident"
                     % (len(shells), EXPECT_SHELLS))
    if open_shells:
        fails.append("%d shell(s) are not closed / consistently wound" % open_shells)
    if inverted:
        fails.append("%d shell(s) have inward-facing normals" % inverted)
    if not fails:
        print("PY: solid check OK: every shell closed, consistently wound, "
              "positive volume (no inside-out parts)")
    return fails


def verify_motion(path, budget_names):
    """Re-derive the animation from the glb alone and check it actually moves.

    Structure checks (a skins array exists, an animations array exists) do not
    prove the rig works — a rig can export perfectly and still be frozen, or
    have both tripods stepping in unison. So: walk the node hierarchy applying
    the sampled TRS, skin the six claw-tip vertices by hand with the glTF
    formula, and measure the foot trajectories that come out.
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

    skin = doc["skins"][0]
    joints = skin["joints"]
    ibm = read_accessor(doc, blob, skin["inverseBindMatrices"])
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

    # claw tips = the vertices sitting exactly on the ground plane in rest
    # claw tips. The exporter splits vertices per face for flat shading, so the
    # 6 tips arrive as 18 coincident vertices -- count distinct POSITIONS.
    feet = [i for i, p in enumerate(pos) if abs(p[1]) < 1e-6]
    foot_bone, seen = {}, set()
    for i in feet:
        b = max(zip(wgt[i], jnt[i]))[1]
        key = tuple(round(c, 6) for c in pos[i])
        if key in seen:
            continue
        seen.add(key)
        foot_bone[i] = names[joints[b]]
    print("PY: ground-plane vertices: %d, at %d distinct positions, driven by %s"
          % (len(feet), len(seen), sorted(foot_bone.values())))
    if len(seen) != 6:
        fails.append("expected 6 distinct claw tips on the ground plane, found %d"
                     % len(seen))
    if sorted(foot_bone.values()) != sorted("leg_%s%d_tibia" % (sd, i)
                                            for _, sd in SIDES for i in (1, 2, 3)):
        fails.append("claw tips are not each driven by their own tibia: %s"
                     % sorted(foot_bone.values()))

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

        def skinned(k, vi):
            W = world_at(k)
            out = Vector((0.0, 0.0, 0.0))
            p = Vector(pos[vi])
            for w, j in zip(wgt[vi], jnt[vi]):
                if w > 0.0:
                    out += (W[joints[j]] @ IBM[j] @ p) * w
            return out

        tracks = {foot_bone[i]: [skinned(k, i) for k in range(len(times))]
                  for i in foot_bone}

        # loop closure: the last key must reproduce the first
        worst = max((tracks[n][0] - tracks[n][-1]).length for n in tracks)
        print("PY: anim '%s': %d samples, %.3f..%.3f s, loop closure error %.6f m"
              % (aname, len(times), times[0], times[-1], worst))
        if worst > 1e-4:
            fails.append("anim '%s' does not loop (foot drift %.5f m)" % (aname, worst))

        # Phase from the fundamental Fourier component of the foot-height
        # signal. argmax is one sample wide and the body sway shifts it, which
        # made an in-phase tripod look staggered; this does not care.
        def phase(ys):
            n = len(ys) - 1                       # drop the duplicated last key
            c = sum(complex(ys[k]) * cmath.exp(-2j * math.pi * k / n)
                    for k in range(n))
            return math.degrees(cmath.phase(c)) % 360.0

        peak = {}
        for n in sorted(tracks):
            ys = [p.y for p in tracks[n]]
            zs = [p.z for p in tracks[n]]
            xs = [p.x for p in tracks[n]]
            lift = max(ys) - min(ys)
            stride = max(zs) - min(zs)
            peak[n] = phase(ys)
            print("PY: anim '%s' foot %-14s lift %.4f m, fore/aft %.4f m, "
                  "lateral %.4f m, min height %.4f m, step phase %6.1f deg"
                  % (aname, n, lift, stride, max(xs) - min(xs), min(ys), peak[n]))
            lateral = max(xs) - min(xs)
            if min(ys) < -0.006:
                fails.append("%s: foot %s sinks %.4f m through the ground plane"
                             % (aname, n, -min(ys)))
            if aname == "run":
                if lift < 0.030:
                    fails.append("run: foot %s lifts only %.4f m, not a readable "
                                 "step" % (n, lift))
                if stride < 0.080:
                    fails.append("run: foot %s travels only %.4f m fore/aft"
                                 % (n, stride))
                if min(ys) > 0.004:
                    fails.append("run: foot %s never plants (min height %.4f m)"
                                 % (n, min(ys)))
                # the point of a stride is that it points where the animal is
                # going; a leg whose sideways sweep rivals its fore/aft travel
                # is rowing
                if lateral > 0.85 * stride:
                    fails.append("run: foot %s sweeps %.4f m laterally against "
                                 "%.4f m of stride; it is rowing, not striding"
                                 % (n, lateral, stride))
            else:
                if lift > 0.010:
                    fails.append("idle: foot %s lifts %.4f m; an idle must keep "
                                 "all six feet on the ground" % (n, lift))

        if aname == "run":
            # alternating tripod: A = l1/r2/l3 steps, B = r1/l2/r3 steps, half
            # a cycle apart. Same-tripod feet must peak together, opposite
            # tripods must not.
            A = ["leg_l1_tibia", "leg_r2_tibia", "leg_l3_tibia"]
            B = ["leg_r1_tibia", "leg_l2_tibia", "leg_r3_tibia"]

            def spread(g):
                ref = peak[g[0]]
                d = [((peak[x] - ref + 180.0) % 360.0) - 180.0 for x in g]
                return max(d) - min(d)

            pa = sum(peak[x] for x in A) / 3.0
            pb = sum(peak[x] for x in B) / 3.0
            off = abs(((pa - pb + 180.0) % 360.0) - 180.0)
            print("PY: run tripod A %s mean phase %.1f deg, spread %.1f deg"
                  % (A, pa, spread(A)))
            print("PY: run tripod B %s mean phase %.1f deg, spread %.1f deg"
                  % (B, pb, spread(B)))
            print("PY: run tripod separation = %.1f deg (want 180 for an "
                  "alternating tripod gait)" % off)
            for g, nm in ((A, "A"), (B, "B")):
                if spread(g) > 15.0:
                    fails.append("run: tripod %s legs are %.1f deg apart, not "
                                 "stepping in unison" % (nm, spread(g)))
            if abs(off - 180.0) > 15.0:
                fails.append("run: tripods are %.1f deg apart, not antiphase" % off)
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
    min_z = min(v[2] for v in b.v)
    print("PY: raw lowest vertex z = %.6f m (claw tips are authored at 0)" % min_z)
    if abs(min_z) > 1e-9:
        b.v = [(x, y, z - min_z) for (x, y, z) in b.v]
        print("PY: applied ground-contact shift of %.6f m" % (-min_z))
    z_shift = -min_z

    me = bpy.data.meshes.new("swarmer_body_mesh")
    me.from_pydata(b.v, [], b.f)
    me.update()
    for m in mats:
        me.materials.append(m)
    for i, mi in enumerate(b.m):
        me.polygons[i].material_index = mi
    mesh_ob = bpy.data.objects.new("swarmer_body", me)
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
    arm_ob = build_armature("AlienSwarmer", z_shift)
    bones = [d[0] for d in bone_defs()]
    print("PY: armature '%s' has %d bones: %s"
          % (arm_ob.name, len(arm_ob.data.bones), ", ".join(bones)))
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
    P = Poser(arm_ob)
    bake_action(arm_ob, P, axes, "idle", 48, 4, pose_idle)
    bake_action(arm_ob, P, axes, "run", RUN_FRAMES, 1, pose_run)
    P.clear()
    P.apply()                       # leave the rig at rest for the bind pose

    # --- export -------------------------------------------------------------
    path = os.path.join(OUT, "alien_swarmer.glb")
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

    promised = ["AlienSwarmer", "swarmer_body"] + bones
    total, size, fails = audit(path, promised, bones, ["idle", "run"], TRI_BUDGET)

    fails += verify_solids(path)
    fails += verify_motion(path, promised)

    if fails:
        for f in fails:
            print("PY: FAIL %s" % f)
        raise SystemExit("FAIL: %d assertion(s) failed" % len(fails))
    print("PY: ===== summary =====")
    print("PY: alien_swarmer %d tris, %.3f x %.3f x %.3f m (width, height, length)"
          % (total, size[0], size[1], size[2]))
    print("PY: ALL CHECKS PASSED")


main()
