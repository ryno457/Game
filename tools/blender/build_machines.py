"""SENTINEL — procedural machine units (collector drone, guard fighter).

Two units, one .glb each, built from explicit triangle lists so the triangle
count is known exactly before export and can be asserted against the exported
glTF afterwards.

    ~/.cache/blender-venv/bin/python tools/blender/build_machines.py [out_dir]

Conventions (project asset pass):
  * metres, Z-up in Blender; the glTF exporter converts to Y-up for Godot
  * origin at the ground contact point (lowest geometry sits at z = 0)
  * solid colours + emission only, no UVs, no textures
  * fully deterministic: there is not a single random call in this file, so two
    runs are byte-identical by construction rather than by seeding

RIGGING — part-based hierarchy, no armature, no skinning.
  These units render through MultiMesh. A MultiMesh draws ONE mesh with a
  per-instance transform buffer; it has no per-instance bone palette, so a
  skinned mesh cannot be instanced that way at all. The moving parts are
  therefore separate child nodes: Godot keeps one MultiMesh per part and writes
  each part's world transform into that part's instance buffer. That also means
  part count is a per-frame CPU cost multiplied by the unit count, so the
  hierarchy is deliberately shallow and the four rotors SHARE one mesh
  datablock (one MultiMesh, four instances per drone).

Node contract for Godot:
    drone.glb  Drone > drone_body
                     > rotor_0 rotor_1 rotor_2 rotor_3   (spin about local Y)
                     > claw > claw_jaw_l, claw_jaw_r, carry_point
    guard.glb  Guard > guard_hull
                     > weapon_arm > weapon_muzzle
                     > hardpoint_l
  Every moving node's pivot is ON its axis of rotation, so Godot rotates the
  node directly with no offset fudging.

The mesh/material/audit machinery below is deliberately a copy of the same
machinery in build_structures.py rather than a shared import: that file runs its
main() at import time, and turning it into a library mid-asset-pass is a riskier
change than duplicating ~150 lines of boring helpers.
"""
import bpy, sys, os, math, struct, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mathutils import Matrix, Vector

from _bl import script_args  # noqa: F401  (kept so both front ends work)

argv = script_args()
OUT = argv[0] if argv else "models"
OUT = os.path.abspath(OUT)
os.makedirs(OUT, exist_ok=True)

TRI_BUDGET = 600            # hard limit per machine unit (sum over its nodes)

TAU = math.tau


# --- palette ----------------------------------------------------------------
# The hexes in the brief are sRGB. glTF baseColorFactor / emissiveFactor are
# LINEAR, so convert; feeding the raw sRGB bytes in as linear renders roughly
# two stops too dark.
def _s2l(b):
    c = b / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


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
#
# Consequences worth writing down, because they are what Godot ends up rotating:
#   design +X (forward)  -> Godot -Z   (unit forward)
#   design +Y (left)     -> Godot -X   (so design -Y is the unit's RIGHT)
#   design +Z (up)       -> Godot +Y
# so a rotor spinning about design Z spins about Godot's local Y, and the
# weapon arm yaws about Godot Y / pitches about Godot X. Both are the standard
# axes, which is the whole point of baking the orientation in.
ORIENT = Matrix.Rotation(math.pi * 0.5, 4, 'Z')


class MB:
    """Accumulates triangles + per-triangle material index."""

    def __init__(self):
        self.v, self.f, self.m = [], [], []
        self.parts = []          # per-primitive AABB, for the connectivity check

    def _emit(self, verts, tris, mat, M):
        off = len(self.v)
        M = ORIENT @ M
        pts = [M @ Vector(p) for p in verts]
        self.parts.append(([min(p[k] for p in pts) for k in range(3)],
                           [max(p[k] for p in pts) for k in range(3)]))
        self.v.extend(tuple(p) for p in pts)
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


def mesh_from(name, mb, mats):
    me = bpy.data.meshes.new(name + "_mesh")
    me.from_pydata(mb.v, [], mb.f)
    me.update()
    for m in mats:
        me.materials.append(m)
    for i, mi in enumerate(mb.m):
        me.polygons[i].material_index = mi
    return me


def obj(name, me, parent=None, loc=(0, 0, 0), rotz=0.0):
    """Link a node. loc is in design space; ORIENT is applied so it matches the
    baked geometry. rotz is a design-space Z rotation, which commutes with
    ORIENT, so it can be left on the node."""
    o = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(o)
    o.location = ORIENT @ Vector(loc)
    if rotz:
        o.rotation_euler = (0.0, 0.0, rotz)
    if parent is not None:
        o.parent = parent
    return o


def world_parts(node_name, mb, loc=(0, 0, 0), rotz=0.0, base=None):
    """Lift an MB's per-primitive AABBs into whole-asset space, so the
    connectivity check can see parts across node boundaries."""
    M = Matrix.Translation(ORIENT @ Vector(loc)) @ Matrix.Rotation(rotz, 4, 'Z')
    if base is not None:
        M = base @ M
    out = []
    for i, (plo, phi) in enumerate(mb.parts):
        pts = [M @ Vector((x, y, z))
               for x in (plo[0], phi[0])
               for y in (plo[1], phi[1])
               for z in (plo[2], phi[2])]
        out.append(("%s#%d" % (node_name, i),
                    [min(p[k] for p in pts) for k in range(3)],
                    [max(p[k] for p in pts) for k in range(3)]))
    return out


def check_connected(label, parts, tol=0.002):
    """Every primitive must touch at least one other, and the whole thing must
    be one island. This is the check that catches a mistyped coordinate parking
    a greeble in mid-air, which is invisible to a triangle count and to a
    bounding box, and which nobody would notice until it shipped."""
    n = len(parts)
    up = list(range(n))

    def find(a):
        while up[a] != a:
            up[a] = up[up[a]]
            a = up[a]
        return a

    def overlap(a, b):
        return all(a[1][k] <= b[2][k] + tol and b[1][k] <= a[2][k] + tol
                   for k in range(3))

    for i in range(n):
        for j in range(i + 1, n):
            if overlap(parts[i], parts[j]):
                ri, rj = find(i), find(j)
                if ri != rj:
                    up[ri] = rj
    islands = {}
    for i in range(n):
        islands.setdefault(find(i), []).append(parts[i][0])
    print("PY: %s connectivity: %d primitives -> %d island(s) (%.0f mm tolerance)"
          % (label, n, len(islands), tol * 1000))
    if len(islands) != 1:
        for k, v in sorted(islands.items(), key=lambda kv: len(kv[1])):
            print("PY: %s island of %d: %s" % (label, len(v), v))
        raise SystemExit("FAIL %s: model is in %d disconnected pieces" % (label, len(islands)))
    return True


def empty(name, parent, loc):
    e = bpy.data.objects.new(name, None)
    e.empty_display_type = 'ARROWS'
    e.empty_display_size = 0.10
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
# DRONE  —  collector quadrotor, ~1.11 m span, ~0.60 m tall on its skids
# =============================================================================
# Layout numbers kept as named constants because the rotor pivots, the boom
# ends and the skid feet all have to agree, and because Godot reads the same
# pivot heights back out of the glb.
HUB_XY = 0.33                 # rotor hub offset on both design axes
HUB_Z = 0.455                 # rotor pivot height
BLADE_R = 0.22                # blade tip reach from the hub (span = 2*(HUB_XY+BLADE_R))
CLAW_Z = 0.30                 # claw pivot height (bottom of the yoke)
JAW_Y = 0.10                  # jaw hinge offset either side of the claw axis
JAW_Z = -0.115                # jaw hinge height, local to the claw node


def build_drone(mats):
    root = root_empty("Drone")

    # --- airframe -----------------------------------------------------------
    b = MB()
    b.box(HULL, (0.40, 0.30, 0.16), loc=(0.0, 0.0, 0.40))            # hull core
    b.box(HULL, (0.26, 0.21, 0.07), loc=(0.0, 0.0, 0.515))           # upper cowl
    b.box(PLATE, (0.12, 0.19, 0.12), loc=(0.25, 0.0, 0.41))          # sensor head
    b.box(ACCENT, (0.028, 0.13, 0.055), loc=(0.318, 0.0, 0.41))      # sensor lens
    b.box(PLATE, (0.14, 0.23, 0.14), loc=(-0.25, 0.0, 0.41))         # avionics bay
    b.box(ACCENT, (0.02, 0.16, 0.035), loc=(-0.330, 0.0, 0.45))      # rear vent
    b.box(ACCENT, (0.05, 0.05, 0.045), loc=(-0.05, 0.0, 0.5725))     # beacon

    for sx in (1, -1):
        for sy in (1, -1):
            # boom out to the motor pod, along the diagonal
            b.box(PLATE, (0.34, 0.07, 0.05),
                  loc=(0.215 * sx, 0.215 * sy, 0.435),
                  rot=(0, 0, math.pi * 0.25 * (sx * sy)))
            b.box(PLATE, (0.115, 0.115, 0.125),
                  loc=(HUB_XY * sx, HUB_XY * sy, HUB_Z))             # motor pod
            b.box(PLATE, (0.05, 0.05, 0.42),
                  loc=(0.21 * sx, 0.21 * sy, 0.23))                  # skid strut
    for sy in (1, -1):
        b.box(PLATE, (0.52, 0.07, 0.04), loc=(0.0, 0.21 * sy, 0.02))  # skid rail
    b.box(PLATE, (0.12, 0.18, 0.08), loc=(0.0, 0.0, 0.34))            # claw yoke

    body = obj("drone_body", mesh_from("drone_body", b, mats), root)

    # --- rotor: ONE mesh datablock, four nodes -------------------------------
    # Two crossed blade bars read as a four-blade rotor for the price of two
    # boxes; a real four-blade fan would cost twice as much for no extra
    # silhouette once it is spinning.
    r = MB()
    r.cone(PLATE, 6, 0.05, 0.042, 0.055, loc=(0.0, 0.0, 0.03))        # hub
    r.box(PLATE, (BLADE_R * 2.0, 0.036, 0.011), loc=(0.0, 0.0, 0.045))
    r.box(PLATE, (0.036, BLADE_R * 2.0, 0.011), loc=(0.0, 0.0, 0.045))
    rotor_mesh = mesh_from("rotor", r, mats)

    rotors = []
    for i, (sx, sy) in enumerate(((1, 1), (-1, 1), (-1, -1), (1, -1))):
        rotors.append(obj("rotor_%d" % i, rotor_mesh, root,
                          loc=(HUB_XY * sx, HUB_XY * sy, HUB_Z)))

    # --- claw: wrist node + two jaw nodes sharing one mesh --------------------
    c = MB()
    c.cone(PLATE, 6, 0.07, 0.062, 0.055, loc=(0.0, 0.0, -0.0275))     # wrist hub
    c.box(HULL, (0.16, 0.20, 0.055), loc=(0.0, 0.0, -0.0825))         # carriage
    c.box(PLATE, (0.055, 0.24, 0.045), loc=(0.0, 0.0, -0.1325))       # hinge bar
    claw = obj("claw", mesh_from("claw", c, mats), root, loc=(0.0, 0.0, CLAW_Z))

    # Jaw mesh is authored with +Y = inward (toward the claw axis) and hangs
    # down -Z, so the right jaw uses it as-is and the left jaw is the same mesh
    # on a 180 deg node. It opens by rotating about its own local X, which is
    # the drone's forward axis — jaws that swing sideways.
    j = MB()
    j.box(PLATE, (0.09, 0.055, 0.05), loc=(0.0, 0.0, 0.0))            # hinge
    j.box(PLATE, (0.06, 0.045, 0.10), loc=(0.0, 0.012, -0.072))       # shank
    j.box(HULL, (0.08, 0.075, 0.04), loc=(0.0, 0.042, -0.128), rot=(0.7, 0, 0))
    jaw_mesh = mesh_from("claw_jaw", j, mats)
    jaw_r = obj("claw_jaw_r", jaw_mesh, claw, loc=(0.0, -JAW_Y, JAW_Z))
    jaw_l = obj("claw_jaw_l", jaw_mesh, claw, loc=(0.0, JAW_Y, JAW_Z),
                rotz=math.pi)
    empty("carry_point", claw, (0.0, 0.0, -0.20))

    promised = ["Drone", "drone_body", "rotor_0", "rotor_1", "rotor_2",
                "rotor_3", "claw", "claw_jaw_l", "claw_jaw_r", "carry_point"]
    predicted = {
        "drone_body": b.tris,
        "rotor_0..3": "%d x4" % r.tris,
        "claw": c.tris,
        "claw_jaw_l/r": "%d x2" % j.tris,
    }
    rendered = b.tris + 4 * r.tris + c.tris + 2 * j.tris

    claw_M = Matrix.Translation(ORIENT @ Vector((0.0, 0.0, CLAW_Z)))
    parts = world_parts("drone_body", b)
    for i, (sx, sy) in enumerate(((1, 1), (-1, 1), (-1, -1), (1, -1))):
        parts += world_parts("rotor_%d" % i, r,
                             loc=(HUB_XY * sx, HUB_XY * sy, HUB_Z))
    parts += world_parts("claw", c, loc=(0.0, 0.0, CLAW_Z))
    parts += world_parts("claw_jaw_r", j, loc=(0.0, -JAW_Y, JAW_Z), base=claw_M)
    parts += world_parts("claw_jaw_l", j, loc=(0.0, JAW_Y, JAW_Z), rotz=math.pi,
                         base=claw_M)
    return root, promised, predicted, rendered, parts


# =============================================================================
# GUARD  —  hover fighter, 1.30 m tall, one weapon arm on the right shoulder
# =============================================================================
SHOULDER = (-0.06, -0.33, 0.90)      # design-space weapon arm pivot
SKIRT_PHASE = math.pi / 8.0          # flats face front/side, not a vertex


def build_guard(mats):
    root = root_empty("Guard")

    b = MB()
    # --- ground contact: four settling pads under the lift skirt -------------
    for sx in (1, -1):
        for sy in (1, -1):
            b.box(PLATE, (0.14, 0.14, 0.13), loc=(0.26 * sx, 0.26 * sy, 0.065))

    # --- lift skirt / plenum -------------------------------------------------
    b.cone(HULL, 8, 0.42, 0.36, 0.22, loc=(0.0, 0.0, 0.24), phase=SKIRT_PHASE)
    for sy in (1, -1):
        b.box(ACCENT, (0.38, 0.04, 0.03), loc=(0.0, 0.335 * sy, 0.335))

    # --- lower chassis -------------------------------------------------------
    b.box(HULL, (0.66, 0.56, 0.18), loc=(0.0, 0.0, 0.44))
    b.ext(HULL, [(0.33, 0.35), (0.45, 0.44), (0.33, 0.53)], 0.48)      # glacis
    b.box(PLATE, (0.16, 0.42, 0.24), loc=(-0.36, 0.0, 0.45))           # rear pack
    for sy in (1, -1):
        b.box(PLATE, (0.10, 0.08, 0.08), loc=(0.38, 0.20 * sy, 0.40))  # tow lug
        for sx in (1, -1):
            b.box(PLATE, (0.10, 0.10, 0.22), loc=(0.24 * sx, 0.24 * sy, 0.44))

    # --- torso ---------------------------------------------------------------
    b.ext(HULL, [(-0.30, 0.53), (0.30, 0.53), (0.36, 0.70),
                 (0.30, 0.96), (-0.26, 0.96), (-0.34, 0.72)], 0.50)
    for sy in (1, -1):
        b.box(PLATE, (0.48, 0.05, 0.32), loc=(0.0, 0.275 * sy, 0.74))  # flank
        b.box(PLATE, (0.22, 0.14, 0.20), loc=(SHOULDER[0], 0.33 * sy, SHOULDER[2]))
        b.cone(PLATE, 6, 0.07, 0.06, 0.10,
               loc=(-0.40, 0.15 * sy, 0.62), rot=RY90)                 # nozzle
    b.box(ACCENT, (0.02, 0.28, 0.04), loc=(-0.325, 0.0, 0.62))         # back vent

    # --- head ----------------------------------------------------------------
    b.cone(PLATE, 6, 0.16, 0.13, 0.08, loc=(-0.02, 0.0, 1.00))         # collar
    b.box(HULL, (0.26, 0.30, 0.18), loc=(0.0, 0.0, 1.13))
    b.ext(HULL, [(0.13, 1.04), (0.21, 1.11), (0.13, 1.22)], 0.26)      # brow
    b.box(ACCENT, (0.028, 0.19, 0.05), loc=(0.222, 0.0, 1.11))         # eye band
    b.box(PLATE, (0.10, 0.22, 0.14), loc=(-0.16, 0.0, 1.12))           # nape
    b.box(PLATE, (0.035, 0.035, 0.09), loc=(-0.14, 0.09, 1.255))       # antenna

    hull = obj("guard_hull", mesh_from("guard_hull", b, mats), root)

    # --- weapon arm: pivot ON the shoulder axis ------------------------------
    w = MB()
    w.cone(PLATE, 6, 0.10, 0.10, 0.15, loc=(0.0, 0.0, 0.0), rot=RX90)  # shoulder
    w.box(HULL, (0.20, 0.11, 0.12), loc=(0.11, 0.0, -0.02))            # upper arm
    w.box(PLATE, (0.13, 0.14, 0.14), loc=(0.24, 0.0, -0.05))           # elbow
    w.box(HULL, (0.24, 0.15, 0.16), loc=(0.40, 0.0, -0.06))            # receiver
    w.cone(PLATE, 6, 0.085, 0.085, 0.11, loc=(0.36, 0.0, 0.07), rot=RX90)  # drum
    w.box(ACCENT, (0.05, 0.12, 0.12), loc=(0.47, 0.0, -0.06))          # charge coil
    w.box(PLATE, (0.12, 0.11, 0.11), loc=(0.55, 0.0, -0.06))           # shroud
    w.cone(PLATE, 6, 0.045, 0.038, 0.20, loc=(0.60, 0.0, -0.06), rot=RY90)
    w.box(PLATE, (0.075, 0.10, 0.10), loc=(0.725, 0.0, -0.06))         # brake
    w.box(PLATE, (0.11, 0.08, 0.06), loc=(0.52, 0.0, -0.135))          # sight pod

    arm = obj("weapon_arm", mesh_from("weapon_arm", w, mats), root, loc=SHOULDER)
    empty("weapon_muzzle", arm, (0.78, 0.0, -0.06))
    empty("hardpoint_l", root, (SHOULDER[0], -SHOULDER[1], SHOULDER[2]))

    promised = ["Guard", "guard_hull", "weapon_arm", "weapon_muzzle",
                "hardpoint_l"]
    predicted = {"guard_hull": b.tris, "weapon_arm": w.tris}
    parts = world_parts("guard_hull", b) + world_parts("weapon_arm", w, loc=SHOULDER)
    return root, promised, predicted, b.tris + w.tris, parts


# =============================================================================
# export + verification
# =============================================================================
def export_glb(path):
    bpy.ops.export_scene.gltf(
        filepath=path,
        export_format='GLB',
        export_apply=True,
        export_yup=True,
        export_materials='EXPORT',
        use_selection=False,
    )


def read_glb(path):
    with open(path, "rb") as f:
        magic, ver, _total = struct.unpack("<4sII", f.read(12))
        assert magic == b"glTF", "not a glb: %s" % path
        assert ver == 2, "glTF version %d" % ver
        n, kind = struct.unpack("<II", f.read(8))
        assert kind == 0x4E4F534A, "first chunk is not JSON"
        return json.loads(f.read(n).decode("utf-8"))


def _quat(x, y, z, w):
    from mathutils import Quaternion
    return Quaternion((w, x, y, z)).to_matrix().to_4x4()


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


def audit(path, promised_nodes, budget, chassis_node, pivot_nodes):
    doc = read_glb(path)
    nodes = doc.get("nodes", [])
    names = [nd.get("name", "") for nd in nodes]
    label = os.path.basename(path)
    fails = []

    print("PY: --- %s ---" % label)
    print("PY: %s nodes: %s" % (label, ", ".join(n for n in names if n)))

    # --- node contract ------------------------------------------------------
    missing = [n for n in promised_nodes if n not in names]
    if missing:
        fails.append("promised nodes missing: %s" % missing)
    else:
        print("PY: %s node contract OK (%d/%d promised nodes present)"
              % (label, len(promised_nodes), len(promised_nodes)))

    # --- hierarchy ----------------------------------------------------------
    parent_of = {}
    for i, nd in enumerate(nodes):
        for c in nd.get("children", []):
            parent_of[c] = i
    for i, nd in enumerate(nodes):
        nm = nd.get("name", "?")
        if nm in promised_nodes:
            p = parent_of.get(i)
            print("PY: %s parent of '%s' = %s"
                  % (label, nm, nodes[p].get("name", "?") if p is not None else "<scene root>"))

    # --- triangles per mesh, from the index accessors the exporter wrote -----
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

    # --- world AABB per node + whole asset ----------------------------------
    lo = [float("inf")] * 3
    hi = [float("-inf")] * 3
    per_node_box = {}
    world_pivot = {}

    def walk(idx, parent):
        nd = nodes[idx]
        M = parent @ node_matrix(nd)
        world_pivot[nd.get("name", "?")] = M @ Vector((0.0, 0.0, 0.0))
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

    # --- budget -------------------------------------------------------------
    total = 0
    mesh_users = {}
    for nd in nodes:
        if "mesh" in nd:
            t = mesh_tris[nd["mesh"]]
            total += t
            mesh_users.setdefault(nd["mesh"], []).append(nd.get("name", "?"))
            print("PY: %s node '%s' -> mesh %d, triangles = %d"
                  % (label, nd.get("name", "?"), nd["mesh"], t))
    for mi, users in sorted(mesh_users.items()):
        if len(users) > 1:
            print("PY: %s mesh %d SHARED by %d nodes %s (one MultiMesh, %d instances)"
                  % (label, mi, len(users), users, len(users)))
    unique = sum(mesh_tris[mi] for mi in mesh_users)
    print("PY: %s unique mesh triangles = %d, RENDERED triangles = %d / budget %d"
          % (label, unique, total, budget))
    if total > budget:
        fails.append("%d rendered tris over budget %d" % (total, budget))

    # --- size ---------------------------------------------------------------
    # glTF is Y-up: x = lateral, y = height, z = depth (unit forward is -Z)
    size = [hi[k] - lo[k] for k in range(3)]
    print("PY: %s bbox min (%.4f, %.4f, %.4f) max (%.4f, %.4f, %.4f) metres"
          % (label, lo[0], lo[1], lo[2], hi[0], hi[1], hi[2]))
    print("PY: %s size lateral X=%.4f  height Y=%.4f  depth Z=%.4f metres"
          % (label, size[0], size[1], size[2]))

    if abs(lo[1]) > 1e-4:
        fails.append("ground contact not at 0 (min Y = %.6f)" % lo[1])
    else:
        print("PY: %s ground contact OK (min Y = %.6f)" % (label, lo[1]))

    cx = (lo[0] + hi[0]) * 0.5
    cz = (lo[2] + hi[2]) * 0.5
    print("PY: %s whole-asset XZ centre offset = (%.4f, %.4f) metres" % (label, cx, cz))
    if abs(cx) > 0.02:
        fails.append("not laterally centred: X centre offset %.4f m" % cx)
    else:
        print("PY: %s lateral centring OK (|X centre| = %.4f m <= 0.02)" % (label, abs(cx)))

    if chassis_node in per_node_box:
        clo, chi = per_node_box[chassis_node]
        ccx = (clo[0] + chi[0]) * 0.5
        ccz = (clo[2] + chi[2]) * 0.5
        print("PY: %s chassis '%s' bbox %.3f x %.3f x %.3f m, XZ centre offset (%.4f, %.4f) m"
              % (label, chassis_node, chi[0] - clo[0], chi[1] - clo[1], chi[2] - clo[2],
                 ccx, ccz))
        if abs(ccx) > 0.02 or abs(ccz) > 0.05:
            fails.append("chassis '%s' not centred in XZ: (%.4f, %.4f)"
                         % (chassis_node, ccx, ccz))
        else:
            print("PY: %s chassis centring OK" % label)

    # --- moving-part pivots -------------------------------------------------
    for n in pivot_nodes:
        if n in world_pivot:
            p = world_pivot[n]
            print("PY: %s pivot '%s' world = (%.4f, %.4f, %.4f) m (glTF X,Y,Z)"
                  % (label, n, p[0], p[1], p[2]))
        else:
            fails.append("pivot node '%s' never reached by the scene walk" % n)

    # --- rigging: part-based, must NOT be skinned ---------------------------
    if "skins" in doc:
        fails.append("glb has a skins array; this asset must be part-based")
    else:
        print("PY: %s skins: none (part-based hierarchy, as intended)" % label)
    if any("skin" in nd for nd in nodes):
        fails.append("a node references a skin")
    if doc.get("animations"):
        fails.append("unexpected animations array")
    else:
        print("PY: %s animations: none (Godot drives the part nodes)" % label)

    # --- materials ----------------------------------------------------------
    emissive = [m.get("name", "?") for m in doc.get("materials", [])
                if any(v > 0.0 for v in m.get("emissiveFactor", [0, 0, 0]))]
    print("PY: %s materials = %s ; emissive = %s"
          % (label, [m.get("name") for m in doc.get("materials", [])], emissive))
    if not emissive:
        fails.append("no emissive material survived export")
    if doc.get("images") or doc.get("textures"):
        fails.append("textures present, this project has no texture pipeline")
    else:
        print("PY: %s no textures/images in glb OK" % label)
    if any("TEXCOORD_0" in p["attributes"]
           for m in doc.get("meshes", []) for p in m["primitives"]):
        print("PY: %s WARNING: a primitive carries UVs (harmless, but unused)" % label)

    if fails:
        for f in fails:
            print("PY: FAIL %s: %s" % (label, f))
        raise SystemExit("FAIL %s: %d assertion(s) failed" % (label, len(fails)))
    print("PY: %s ALL ASSERTIONS PASSED" % label)
    return total, size, per_node_box


SPECS = [
    ("drone", build_drone, "drone_body",
     ["rotor_0", "rotor_1", "rotor_2", "rotor_3", "claw", "claw_jaw_l",
      "claw_jaw_r", "carry_point"]),
    ("guard", build_guard, "guard_hull",
     ["weapon_arm", "weapon_muzzle", "hardpoint_l"]),
]


def main():
    results = []
    for name, fn, chassis, pivots in SPECS:
        mats = new_scene()
        root, promised, predicted, rendered, parts = fn(mats)
        print("PY: %s built in blender, predicted tris %s -> rendered %d"
              % (name, predicted, rendered))
        check_connected(name, parts)
        path = os.path.join(OUT, name + ".glb")
        export_glb(path)
        print("PY: exported %s (%d bytes)" % (path, os.path.getsize(path)))
        total, size, boxes = audit(path, promised, TRI_BUDGET, chassis, pivots)
        if total != rendered:
            raise SystemExit("FAIL %s: blender predicted %d rendered tris, glb has %d"
                             % (name, rendered, total))
        print("PY: %s predicted-vs-exported triangle count agrees (%d)" % (name, total))
        for n, (blo, bhi) in sorted(boxes.items()):
            print("PY: %s node '%s' bbox size = (%.3f, %.3f, %.3f) m"
                  % (name, n, bhi[0] - blo[0], bhi[1] - blo[1], bhi[2] - blo[2]))
        results.append((name, total, size))

    print("PY: ===== summary =====")
    for name, total, size in results:
        print("PY: %-6s %4d tris / %d   %.3f x %.3f x %.3f m (lateral, height, depth)"
              % (name, total, TRI_BUDGET, size[0], size[1], size[2]))
    print("PY: ALL CHECKS PASSED")


main()
