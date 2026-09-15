"""Render the biodome map that Godot actually builds, so it can be LOOKED at.

Validation, not art. The map is authored as a seed plus a list of ops and the
dressing as a seed plus scatter rules — the headless checks can say the pools
cut the valley and the path goes through end to end, but they cannot say
whether it reads as the place in the reference painting. This can.

    godot --headless --path . --script tools/build_biodome.gd
    ~/.cache/blender-venv/bin/python tools/blender/biodome_preview.py \
        build/biodome models build/biodome

Everything here is read from what Godot wrote: the same heightfield, the same
prop transforms, the same palette. If this render disagrees with the game, the
render is wrong.
"""
import bpy, sys, os, json, struct, math

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mathutils import Matrix, Vector
from _bl import script_args, render, cycles_cpu

argv = script_args()
DATA = argv[0] if argv else "build/biodome"
MODELS = argv[1] if len(argv) > 1 else "models"
OUT = argv[2] if len(argv) > 2 else DATA
os.makedirs(OUT, exist_ok=True)

meta = json.load(open(os.path.join(DATA, "biodome_01.json")))
CX, CZ = meta["cells_x"], meta["cells_z"]
HS = meta["height_scale_m"]
IMPASSABLE, ROUGH = meta["impassable_below"], meta["rough_below"]
PAL = meta["palette"]

with open(os.path.join(DATA, "biodome_01.r32"), "rb") as f:
    heights = struct.unpack("<%df" % (CX * CZ), f.read())
print("PY: %d cells, %d prop kinds" % (len(heights), len(meta["props"])))


def _s2l(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def rgb(h):
    return tuple(_s2l(int(h[i:i + 2], 16) / 255.0) for i in (0, 2, 4)) + (1.0,)


bpy.ops.wm.read_factory_settings(use_empty=True)

# --- the ground -------------------------------------------------------------
mesh = bpy.data.meshes.new("biodome")
obj = bpy.data.objects.new("biodome", mesh)
bpy.context.collection.objects.link(obj)
verts = [(x, z, heights[z * CX + x] * HS) for z in range(CZ) for x in range(CX)]
faces = [(z * CX + x, z * CX + x + 1, (z + 1) * CX + x + 1, (z + 1) * CX + x)
         for z in range(CZ - 1) for x in range(CX - 1)]
mesh.from_pydata(verts, [], faces)
mesh.update()
mesh.polygons.foreach_set("use_smooth", [True] * len(mesh.polygons))

# Vertex colours by the same three-way band the shader uses, so a severed
# trench is as unmistakable here as it is in the game.
col = mesh.color_attributes.new("band", 'FLOAT_COLOR', 'POINT')
lit = mesh.color_attributes.new("glow", 'FLOAT_COLOR', 'POINT')
pool, rough, ground, ridge = (rgb(PAL["pool"]), rgb(PAL["rough"]),
                              rgb(PAL["ground"]), rgb(PAL["ridge"]))
glow = rgb(PAL["pool_glow"])
STRENGTH = float(PAL["pool_glow_strength"])
for i, h in enumerate(heights):
    if h < IMPASSABLE:
        c = pool
    elif h < ROUGH:
        t = (h - IMPASSABLE) / max(1e-3, ROUGH - IMPASSABLE)
        c = tuple(pool[k] + (rough[k] - pool[k]) * t for k in range(4))
    else:
        t = min(1.0, (h - ROUGH) / 0.42)
        c = tuple(ground[k] + (ridge[k] - ground[k]) * t for k in range(4))
    col.data[i].color = c

    # The same shoreline feather the shader applies: brightest at the deepest
    # point, fading out over the last few centimetres above the waterline.
    # Baked per-vertex rather than faked with an emissive plane, because a
    # plane cuts a straight edge across the map wherever it ends — which is
    # exactly what the first version of this render did.
    depth = max(0.0, (IMPASSABLE - h) / max(1e-3, IMPASSABLE))
    shore = min(1.0, max(0.0, (IMPASSABLE + 0.03 - h) / 0.08))
    e = STRENGTH * shore * (0.25 + 0.75 * depth)
    lit.data[i].color = tuple(glow[k] * e for k in range(3)) + (1.0,)

gmat = bpy.data.materials.new("ground")
gmat.use_nodes = True
nt = gmat.node_tree
bsdf = nt.nodes["Principled BSDF"]
attr = nt.nodes.new("ShaderNodeVertexColor")
attr.layer_name = "band"
nt.links.new(attr.outputs["Color"], bsdf.inputs["Base Color"])
bsdf.inputs["Roughness"].default_value = 0.8
emis_attr = nt.nodes.new("ShaderNodeVertexColor")
emis_attr.layer_name = "glow"
nt.links.new(emis_attr.outputs["Color"], bsdf.inputs["Emission Color"])
bsdf.inputs["Emission Strength"].default_value = 1.0

# Surface detail, matching what the game's shader does per fragment: a bump
# from one octave of noise, and a very low-frequency colour drift. Without
# these the render shows smooth plastic ground and the game shows grit, and a
# preview that flatters the game is worse than no preview.
bump_noise = nt.nodes.new("ShaderNodeTexNoise")
bump_noise.inputs["Scale"].default_value = 2.6      # cycles per metre
bump_noise.inputs["Detail"].default_value = 1.0
bump = nt.nodes.new("ShaderNodeBump")
bump.inputs["Strength"].default_value = 0.28
bump.inputs["Distance"].default_value = 0.06
nt.links.new(bump_noise.outputs["Fac"], bump.inputs["Height"])
nt.links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])

# No macro-variation node here. The game's shader does apply one, but an
# OVERLAY mix against a mid-grey noise lifts the ground's average brightness,
# and in Cycles that extra bounce washed out every prop standing on it — the
# render came back paler than the game while claiming to represent it. The
# bump above is representative; a colour-balance change is not worth the lie.

mesh.materials.append(gmat)

# --- the dressing -----------------------------------------------------------
# Imported once and linked, so 230 props cost 230 object headers and six
# meshes rather than 230 copies of the geometry.
placed = 0
for kind in meta["props"]:
    path = os.path.join(MODELS, kind["model"] + ".glb")
    if not os.path.exists(path):
        print("PY: missing %s" % path)
        continue
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    imported = [o for o in set(bpy.data.objects) - before if o.type == 'MESH']
    if not imported:
        continue
    src = imported[0]
    # No vertex-colour surgery here. Blender's glTF importer ALREADY wires
    # COLOR_0 into Base Color when the mesh carries it, through a link — so the
    # Principled node's own default_value is left at white. An earlier version
    # of this read that white default, multiplied it by the occlusion and
    # replaced the link with the result, which threw away every prop's actual
    # colour and rendered the whole biodome grey. The importer has it right;
    # leave it alone. (Godot is the one that needs the fix, in ModelLibrary,
    # because ITS importer enables vertex colour on the wrong materials.)
    for o in set(bpy.data.objects) - before:
        o.hide_render = True
    for row in kind["at"]:
        # Godot is Y-up, Blender is Z-up: (x, y, z) -> (x, z, y), and the same
        # swap applied to each basis column.
        def g2b(v):
            return Vector((v[0], v[2], v[1]))
        M = Matrix((
            (row["x"][0], row["z"][0], row["y"][0], row["o"][0]),
            (row["x"][2], row["z"][2], row["y"][2], row["o"][2]),
            (row["x"][1], row["z"][1], row["y"][1], row["o"][1]),
            (0.0, 0.0, 0.0, 1.0)))
        dup = bpy.data.objects.new(kind["model"] + "_i", src.data)
        bpy.context.collection.objects.link(dup)
        dup.matrix_world = M
        placed += 1
print("PY: placed %d props" % placed)

# --- light it like the game -------------------------------------------------
# One weak, low sun and a dark sky. Everything else in this image is alive.
sun_data = bpy.data.lights.new("sun", 'SUN')
sun_data.energy = 2.1
sun_data.angle = math.radians(3.0)
sun_data.color = (0.62, 0.78, 0.95)
sun = bpy.data.objects.new("sun", sun_data)
bpy.context.collection.objects.link(sun)
sun.rotation_euler = (math.radians(58.0), 0.0, math.radians(-38.0))

world = bpy.data.worlds.new("w")
bpy.context.scene.world = world
world.use_nodes = True
bg = world.node_tree.nodes["Background"]
bg.inputs["Color"].default_value = (0.012, 0.045, 0.055, 1.0)
bg.inputs["Strength"].default_value = 0.55

sc = bpy.context.scene
cycles_cpu(sc, 64)
sc.view_settings.view_transform = 'AgX'
sc.view_settings.look = 'AgX - Punchy'


def shoot(name, loc, look_at, res=(1280, 800), lens=38.0, ortho=None):
    cam_data = bpy.data.cameras.new("c_" + name)
    if ortho:
        cam_data.type = 'ORTHO'
        cam_data.ortho_scale = ortho
    else:
        cam_data.lens = lens
    cam = bpy.data.objects.new("c_" + name, cam_data)
    bpy.context.collection.objects.link(cam)
    cam.location = loc
    d = Vector(look_at) - Vector(loc)
    cam.rotation_euler = d.to_track_quat('-Z', 'Y').to_euler()
    sc.camera = cam
    sc.render.resolution_x, sc.render.resolution_y = res
    sc.render.filepath = os.path.join(OUT, "biodome_01_%s.png" % name)
    render(sc)
    print("PY: wrote %s" % sc.render.filepath)


land = meta["landing"]
# Eye level, looking down the pale path from just behind the landing site —
# roughly the RTS camera the game uses, so this is what the player will see.
shoot("path", (land[0] - 22.0, land[1] - 16.0, 26.0), (land[0] + 44.0, land[1] + 16.0, 2.0))
# The far end of the valley, where the channels braid.
shoot("valley", (118.0, 26.0, 30.0), (84.0, 76.0, 2.0))
# The whole map, so the shape of the thing is legible in one frame.
shoot("plan", (CX * 0.5, CZ * 0.5 - 1.0, 150.0), (CX * 0.5, CZ * 0.5, 0.0),
      res=(1100, 830), ortho=CX * 1.02)
