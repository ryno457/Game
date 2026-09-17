"""Render the game's own shot: Godot's camera, Godot's sun, the module on the map.

    godot --headless --path . --script tools/build_biodome.gd
    ~/.cache/blender-venv/bin/python tools/blender/game_camera.py \
        build/biodome models build/biodome

Every number that decides the framing is READ from what Godot exported, not
typed here. That is the whole point of this file. biodome_preview.py's "roughly
the RTS camera" shot was a hand-picked 38 mm lens at a hand-picked position with
a sun of its own, and all three were wrong — which makes a preview worse than no
preview, because it disagrees with the game while claiming not to.

Three things this gets right that a guessed camera does not:

  FOV AXIS. Godot's Camera3D defaults to keep_aspect = KEEP_HEIGHT, so `fov` is
  the VERTICAL angle and the horizontal one opens up with the aspect ratio.
  Measured from the projection matrix at 2340x1080: 58 vertical, 100.4
  horizontal. Read 58 as horizontal and you frame a much tighter shot.

  HANDEDNESS. Godot is Y-up, Blender is Z-up, and the obvious swap
  (x, y, z) -> (x, z, y) has determinant -1: it MIRRORS the world. The other
  preview scripts do exactly that, consistently, so their images are mirror
  images of the game. Here the map is (x, y, z) -> (x, -z, y), which preserves
  handedness, so left in this render is left on the phone.

  THE SUN. One source. The angles come from data/gameplay/lighting.tres by way
  of the export, the same ones TerrainBuilder.bake_shade marches cast shadows
  along.

This is Cycles, not Godot's renderer, so it is not a pixel prediction — there is
no tonemapper match, no custom light(), none of the terrain shader's painted
ramp. It answers a narrower and more useful question: from the camera the game
actually uses, is the module the right size in frame, does the ground read, and
is there anything worth looking at where the player will be looking.
"""
import bpy, sys, os, json, struct, math

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mathutils import Matrix, Vector
from _bl import script_args, render, cycles_cpu
import _ravine

argv = script_args()
DATA = argv[0] if argv else "build/biodome"
MODELS = argv[1] if len(argv) > 1 else "models"
OUT = argv[2] if len(argv) > 2 else DATA
os.makedirs(OUT, exist_ok=True)

meta = json.load(open(os.path.join(DATA, "biodome_01.json")))
CX, CZ = meta["cells_x"], meta["cells_z"]
HS = meta["height_scale_m"]
VOID = meta.get("void_below", 0.0)
IMPASSABLE = meta["impassable_below"]
PAL = meta["palette"]
VIEW = meta["view"]

with open(os.path.join(DATA, "biodome_01.r32"), "rb") as f:
    heights = struct.unpack("<%df" % (CX * CZ), f.read())
mat_path = os.path.join(DATA, "biodome_01_mat.u8")
matmap = open(mat_path, "rb").read() if os.path.exists(mat_path) else None


def _s2l(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def rgb(h):
    return tuple(_s2l(int(h[i:i + 2], 16) / 255.0) for i in (0, 2, 4)) + (1.0,)


def g2b(x, y, z):
    """Godot (Y-up) to Blender (Z-up), PRESERVING handedness.

    Determinant +1. The naive (x, y, z) -> (x, z, y) is det -1 and silently
    mirrors the scene; see the module docstring.
    """
    return Vector((x, -z, y))


def height_at(cx, cz):
    """Bilinear, in cell coordinates — the same read the game's vertex stage does."""
    cx = min(max(cx, 0.0), CX - 1.001)
    cz = min(max(cz, 0.0), CZ - 1.001)
    x0, z0 = int(cx), int(cz)
    x1, z1 = min(x0 + 1, CX - 1), min(z0 + 1, CZ - 1)
    fx, fz = cx - x0, cz - z0
    a, b = heights[z0 * CX + x0], heights[z0 * CX + x1]
    c, d = heights[z1 * CX + x0], heights[z1 * CX + x1]
    return ((a + (b - a) * fx) * (1 - fz) + (c + (d - c) * fx) * fz) * HS


bpy.ops.wm.read_factory_settings(use_empty=True)

# --- the ground --------------------------------------------------------------
mesh = bpy.data.meshes.new("biodome")
obj = bpy.data.objects.new("biodome", mesh)
bpy.context.collection.objects.link(obj)
verts = [g2b(x, heights[z * CX + x] * HS, z) for z in range(CZ) for x in range(CX)]
faces = []
for z in range(CZ - 1):
    for x in range(CX - 1):
        quad = (z * CX + x, z * CX + x + 1, (z + 1) * CX + x + 1, (z + 1) * CX + x)
        # The world edge. Godot's shader discards these fragments; not building
        # the face gives the same silhouette for less.
        if VOID > 0.0 and any(heights[i] < VOID for i in quad):
            continue
        faces.append(quad)
mesh.from_pydata(verts, [], faces)
mesh.update()
mesh.polygons.foreach_set("use_smooth", [True] * len(mesh.polygons))
print("PY: ground %d of %d quads" % (len(faces), (CX - 1) * (CZ - 1)))

# Vertex colour straight off the material map, so the ground reads as the five
# materials the game classifies rather than as one flat green.
MATS = [rgb(m["colour"]) for m in meta["materials"]]
col = mesh.color_attributes.new("mat", 'FLOAT_COLOR', 'POINT')
POOL = rgb(PAL["pool"])
for i in range(CX * CZ):
    if heights[i] < IMPASSABLE:
        col.data[i].color = POOL
    elif matmap is not None:
        col.data[i].color = MATS[min(matmap[i], len(MATS) - 1)]
    else:
        col.data[i].color = rgb(PAL["ground"])

gm = bpy.data.materials.new("ground")
gm.use_nodes = True
bsdf = gm.node_tree.nodes["Principled BSDF"]
attr = gm.node_tree.nodes.new("ShaderNodeVertexColor")
attr.layer_name = "mat"
gm.node_tree.links.new(attr.outputs["Color"], bsdf.inputs["Base Color"])
bsdf.inputs["Roughness"].default_value = 0.88
obj.data.materials.append(gm)

# --- the props the game scatters --------------------------------------------
placed = 0
for kind in meta["props"]:
    path = os.path.join(MODELS, kind["model"] + ".glb")
    if not os.path.exists(path):
        continue
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    imported = [o for o in set(bpy.data.objects) - before if o.type == 'MESH']
    if not imported:
        continue
    src = imported[0]
    for o in set(bpy.data.objects) - before:
        o.hide_render = True
    for row in kind["at"]:
        bx, by, bz = row["x"], row["y"], row["z"]
        o = row["o"]
        # Each basis column is a direction, so each goes through g2b too.
        cx_, cy_, cz_ = g2b(*bx), g2b(*by), g2b(*bz)
        t = g2b(*o)
        M = Matrix(((cx_.x, cy_.x, cz_.x, t.x),
                    (cx_.y, cy_.y, cz_.y, t.y),
                    (cx_.z, cy_.z, cz_.z, t.z),
                    (0.0, 0.0, 0.0, 1.0)))
        dup = bpy.data.objects.new(kind["model"] + "_i", src.data)
        bpy.context.collection.objects.link(dup)
        dup.matrix_world = M
        placed += 1
print("PY: placed %d props" % placed)


# --- the module and the drone ------------------------------------------------
def place(model, form, at_xz, scale, yaw_deg=0.0):
    """Drop a model on the ground at a map position, as proto_main does."""
    path = os.path.join(MODELS, model + ".glb")
    if not os.path.exists(path):
        print("PY: no model %s" % path)
        return None
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    new = set(bpy.data.objects) - before
    # module_forms.glb carries all three growth forms in one file and the game
    # spawns ONE of them by name. Importing the file puts all three on top of
    # each other, so everything that is not the wanted form has to go.
    keep = None
    for o in new:
        if o.type != 'MESH':
            continue
        if form is None or o.name.startswith(form):
            keep = o if keep is None else keep
    for o in new:
        if o is not keep:
            o.hide_render = True
    if keep is None:
        print("PY: %s has no form %s" % (model, form))
        return None
    y = height_at(at_xz[0], at_xz[1])
    keep.matrix_world = (Matrix.Translation(g2b(at_xz[0], y, at_xz[1]))
                         @ Matrix.Rotation(math.radians(yaw_deg), 4, 'Z')
                         @ Matrix.Scale(scale, 4))
    keep.hide_render = False
    return keep


TARGET = VIEW["target"]
MODULE_SCALE = float(VIEW["module_scale"])
FORM = VIEW["module_forms"][int(VIEW["module_form"])]
place(VIEW["module_model"], FORM, TARGET, MODULE_SCALE, 18.0)
print("PY: module %s at scale %.2f" % (FORM, MODULE_SCALE))
# The drone sits three metres off in +X, as proto_main puts it.
place(VIEW["drone_model"], None, (TARGET[0] + 3.0, TARGET[1]), 1.0, -35.0)

# --- the ravine under and around the map -------------------------------------
# Ground that falls away has to fall away INTO something, or every off-map
# pixel is flat world-background and the framing reads as broken when it is
# merely open. In the game that something is RavineWall; here it is the coarse
# stand-in in _ravine.py, at the same heights and colours.
_ravine.build(meta["ravine"], CX, CZ, z_sign=-1.0)

# --- the sun the game actually has -------------------------------------------
sun_data = bpy.data.lights.new("sun", 'SUN')
sun_data.energy = float(VIEW["sun_energy"]) * 2.4      # Cycles watts, not Godot energy
sun_data.color = rgb(VIEW["sun_colour"])[:3]
sun_data.angle = math.radians(float(VIEW.get("sun_angular_deg", 1.0)))
sun = bpy.data.objects.new("sun", sun_data)
bpy.context.collection.objects.link(sun)
# Build the direction rather than guessing an Euler triple: azimuth is measured
# clockwise from -Z in Godot's axes, elevation up from the horizon.
az = math.radians(float(VIEW["sun_azimuth_deg"]))
el = math.radians(float(VIEW["sun_elevation_deg"]))
toward = g2b(math.sin(az) * math.cos(el), math.sin(el), -math.cos(az) * math.cos(el))
# A Blender sun shines along its local -Z, so point -Z at the ground: the object
# faces FROM the sun toward the scene.
sun.rotation_euler = (-toward).to_track_quat('-Z', 'Y').to_euler()

world = bpy.data.worlds.new("w")
bpy.context.scene.world = world
world.use_nodes = True
bg = world.node_tree.nodes["Background"]
amb = rgb(VIEW["ambient_colour"])
bg.inputs["Color"].default_value = amb
# Godot's ambient_energy is not Cycles' world strength and there is no exact
# conversion — this is matched by eye so the props read as objects rather than
# as black cut-outs, which is what the literal 0.5x gave.
bg.inputs["Strength"].default_value = float(VIEW["ambient_energy"]) * 1.6

sc = bpy.context.scene
cycles_cpu(sc, 96)
sc.view_settings.view_transform = 'AgX'
sc.view_settings.look = 'AgX - Punchy'

# --- the camera --------------------------------------------------------------
RES = VIEW["resolution"]
cam_data = bpy.data.cameras.new("game")
# VERTICAL fov. sensor_fit FIT would apply the angle to the LONGER axis, which
# on a 2340x1080 landscape frame is the horizontal one — the exact mistake this
# script exists to avoid. 'VERTICAL' pins it to the short axis, as Godot's
# keep_aspect = KEEP_HEIGHT does.
cam_data.sensor_fit = 'VERTICAL'
cam_data.angle_y = math.radians(float(VIEW["fov_deg_vertical"]))
cam_data.clip_start, cam_data.clip_end = 0.05, 600.0
cam = bpy.data.objects.new("game", cam_data)
bpy.context.collection.objects.link(cam)


def shoot(name, rig_xz, note):
    """One frame from the game's camera, with the rig at `rig_xz`.

    proto_main._frame_camera(), exactly: the rig sits at ground level on the
    map and the camera hangs off it by a fixed offset, looking back at it.
    """
    off = VIEW["camera_offset"]
    rig = g2b(rig_xz[0], 0.0, rig_xz[1])
    eye = rig + g2b(off[0], off[1], off[2])
    cam.location = eye
    cam.rotation_euler = (rig - eye).to_track_quat('-Z', 'Y').to_euler()
    sc.render.filepath = os.path.join(OUT, "biodome_01_cam_%s.png" % name)
    render(sc)
    print("PY: wrote %s  (%s)" % (sc.render.filepath, note))


sc.camera = cam
sc.render.resolution_x, sc.render.resolution_y = RES
sc.render.resolution_percentage = 100
off = VIEW["camera_offset"]
pitch = math.degrees(math.atan2(off[1], math.hypot(off[0], off[2])))
print("PY: camera %.1f m up, %.1f deg down, %.1f vertical fov, %dx%d"
      % (off[1], pitch, VIEW["fov_deg_vertical"], RES[0], RES[1]))

# The shot the player actually gets on frame one. Worth having even though it
# is unflattering: the spawn sits 21 m from the map's north edge, and Godot's
# own projection says the top of this frame lands 16 m PAST that edge.
shoot("start", TARGET, "the real starting framing")
# And the same camera over the middle of the map, which is what the rest of the
# game looks like once the player pans.
shoot("centre", (CX * 0.5, CZ * 0.5), "the same camera, mid-map")
