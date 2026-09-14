"""Build a 3D preview of a SENTINEL test map from its raw heightfield.

Not art — this is validation. A heightmap PNG cannot show you that a trench
actually reads as a trench, or that a chokepoint is wide enough to walk
through. Renders on CPU (Cycles); no GPU needed.

    blender --background --python tools/blender/terrain_preview.py -- \
        build/terrain/test_map_01.r32 150 112 build/terrain

Emits <name>_persp.png, <name>_top.png and <name>.glb.
"""
import bpy, sys, os, struct, math, time

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
if len(argv) < 4:
    raise SystemExit("need: <raw.r32> <cells_x> <cells_z> <out_dir>")
RAW, CX, CZ, OUT = argv[0], int(argv[1]), int(argv[2]), argv[3]
NAME = os.path.splitext(os.path.basename(RAW))[0]

# Must match data/terrain/biodome_01.tres
HEIGHT_SCALE = 12.0
IMPASSABLE, ROUGH = 0.26, 0.38

with open(RAW, "rb") as f:
    data = f.read()
heights = struct.unpack("<%df" % (CX * CZ), data)
print("PY: loaded %d cells from %s" % (len(heights), RAW))

bpy.ops.wm.read_factory_settings(use_empty=True)
mesh = bpy.data.meshes.new(NAME)
obj = bpy.data.objects.new(NAME, mesh)
bpy.context.collection.objects.link(obj)

verts = [(x, z, heights[z * CX + x] * HEIGHT_SCALE) for z in range(CZ) for x in range(CX)]
faces = [(z*CX+x, z*CX+x+1, (z+1)*CX+x+1, (z+1)*CX+x)
         for z in range(CZ-1) for x in range(CX-1)]
mesh.from_pydata(verts, [], faces)
mesh.update()
mesh.polygons.foreach_set("use_smooth", [True] * len(mesh.polygons))

# Colour by passability band, as vertex colours — the same three-way read the
# game uses, so a trench that has actually been severed is unmistakable.
col = mesh.color_attributes.new(name="passability", type='FLOAT_COLOR', domain='POINT')
for i, h in enumerate(heights):
    if h <= IMPASSABLE:
        c = (0.05, 0.07, 0.16, 1.0)
    elif h < ROUGH:
        t = (h - IMPASSABLE) / (ROUGH - IMPASSABLE)
        c = (0.42 + 0.13*t, 0.30 + 0.12*t, 0.16 + 0.06*t, 1.0)
    else:
        t = min(1.0, (h - ROUGH) / 0.4)
        c = (0.33 + 0.39*t, 0.31 + 0.39*t, 0.37 + 0.39*t, 1.0)
    col.data[i].color = c

mat = bpy.data.materials.new("passability")
mat.use_nodes = True
nt = mat.node_tree
bsdf = nt.nodes["Principled BSDF"]
bsdf.inputs["Roughness"].default_value = 0.92
attr = nt.nodes.new("ShaderNodeVertexColor")
attr.layer_name = "passability"
nt.links.new(attr.outputs["Color"], bsdf.inputs["Base Color"])
mesh.materials.append(mat)

sun_d = bpy.data.lights.new("sun", type='SUN')
sun_d.energy = 3.5
sun = bpy.data.objects.new("sun", sun_d)
bpy.context.collection.objects.link(sun)
sun.rotation_euler = (math.radians(52), 0, math.radians(38))

world = bpy.data.worlds.new("w")
bpy.context.scene.world = world
world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (0.03, 0.04, 0.07, 1)

sc = bpy.context.scene
sc.render.engine = 'CYCLES'
sc.cycles.device = 'CPU'
sc.cycles.samples = 64
sc.cycles.use_denoising = False        # this build ships without OpenImageDenoise
sc.render.film_transparent = False

cam_d = bpy.data.cameras.new("cam")
cam = bpy.data.objects.new("cam", cam_d)
bpy.context.collection.objects.link(cam)
sc.camera = cam


def shoot(name, loc, rot, ortho=None, res=(960, 640)):
    cam.location = loc
    cam.rotation_euler = rot
    if ortho:
        cam_d.type = 'ORTHO'
        cam_d.ortho_scale = ortho
    else:
        cam_d.type = 'PERSP'
        cam_d.lens = 40
    sc.render.resolution_x, sc.render.resolution_y = res
    sc.render.filepath = os.path.join(OUT, "%s_%s.png" % (NAME, name))
    t = time.time()
    bpy.ops.render.render(write_still=True)
    print("PY: %s render %.1fs -> %s" % (name, time.time() - t, sc.render.filepath))


shoot("persp", (CX * 0.5, -CZ * 0.62, 92), (math.radians(52), 0, 0))
shoot("top", (CX * 0.5, CZ * 0.5, 150), (0, 0, 0), ortho=CX * 1.02, res=(900, 672))

glb = os.path.join(OUT, NAME + ".glb")
bpy.ops.export_scene.gltf(filepath=glb, export_format='GLB')
print("PY: glTF -> %s (%d bytes)" % (glb, os.path.getsize(glb)))
