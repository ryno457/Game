"""Grey-box Sentinel chassis with named module-bay anchors.

Boxes only — CLAUDE.md: "Placeholder capsules and cubes only." The point is
not how it looks, it is that the six bays exist as real transforms so
attach/detach can be a reparent operation instead of hardcoded offsets.

Dimensions come from data/chassis/sentinel.tres (radius_m 1.625).

    blender --background --python tools/blender/build_chassis.py -- <out_dir>
"""
import bpy, sys, os, math, struct, json

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = argv[0] if argv else "build/chassis"
os.makedirs(OUT, exist_ok=True)

BAYS = 6
HULL_L, HULL_W, HULL_H = 3.2, 2.2, 1.0     # metres
TREAD_W, TREAD_H = 0.5, 0.7
BAY_RX, BAY_RY = 1.20, 0.72                 # bay ring radii, inset on the deck
DECK_Z = HULL_H + 0.05                      # ON the deck, not inside the hull

bpy.ops.wm.read_factory_settings(use_empty=True)
root = bpy.data.objects.new("SentinelChassis", None)
root.empty_display_type = 'PLAIN_AXES'
bpy.context.collection.objects.link(root)


def box(name, size, loc, parent, colour):
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=loc)
    o = bpy.context.active_object
    o.name = name
    o.scale = size
    bpy.ops.object.transform_apply(scale=True)
    o.parent = parent
    m = bpy.data.materials.new(name + "_mat")
    m.use_nodes = True
    m.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = colour
    m.node_tree.nodes["Principled BSDF"].inputs["Roughness"].default_value = 0.75
    o.data.materials.append(m)
    return o


HULL = (0.07, 0.19, 0.23, 1.0)
TREAD = (0.09, 0.13, 0.17, 1.0)
CORE = (0.56, 1.0, 0.94, 1.0)

box("hull", (HULL_L, HULL_W, HULL_H), (0, 0, HULL_H * 0.5), root, HULL)
box("prow", (0.7, HULL_W * 0.72, HULL_H * 0.8), (HULL_L * 0.5 + 0.3, 0, HULL_H * 0.5), root, HULL)
box("tread_l", (HULL_L * 1.05, TREAD_W, TREAD_H),
    (0, -(HULL_W * 0.5 + TREAD_W * 0.5), TREAD_H * 0.5), root, TREAD)
box("tread_r", (HULL_L * 1.05, TREAD_W, TREAD_H),
    (0, HULL_W * 0.5 + TREAD_W * 0.5, TREAD_H * 0.5), root, TREAD)
box("core", (0.5, 0.5, 0.36), (0, 0, HULL_H + 0.16), root, CORE)

# --- the actual deliverable: six named bay anchors ---------------------------
# Bay 0 sits at the prow, the rest anticlockwise viewed from above. A module
# node is reparented to one of these; nothing about attaching should need a
# magic offset in code. They sit ON the deck so they stay visible from the
# RTS camera, which looks down.
for i in range(BAYS):
    a = (i / BAYS) * math.tau               # bay_0 at the prow, then anticlockwise
    e = bpy.data.objects.new("bay_%d" % i, None)
    e.empty_display_type = 'ARROWS'
    e.empty_display_size = 0.35
    e.location = (math.cos(a) * BAY_RX, math.sin(a) * BAY_RY, DECK_Z)
    # Point each bay outward, so a detaching module already faces away.
    e.rotation_euler = (0, 0, a)
    bpy.context.collection.objects.link(e)
    e.parent = root

glb = os.path.join(OUT, "chassis_placeholder.glb")
bpy.ops.export_scene.gltf(filepath=glb, export_format='GLB')
print("PY: exported %s (%d bytes)" % (glb, os.path.getsize(glb)))

# Verify the empties actually survived export — glTF exporters have been known
# to drop parentless/childless empties, and a silently missing bay would be
# discovered much later and much more annoyingly.
with open(glb, "rb") as f:
    assert f.read(4) == b"glTF"
    struct.unpack("<II", f.read(8))
    n, kind = struct.unpack("<II", f.read(8))
    doc = json.loads(f.read(n).decode("utf-8"))
names = [nd.get("name", "") for nd in doc.get("nodes", [])]
found = sorted(x for x in names if x.startswith("bay_"))
print("PY: nodes in glb: %s" % ", ".join(names))
print("PY: bays found: %d/%d -> %s" % (len(found), BAYS, found))
if len(found) != BAYS:
    raise SystemExit("FAIL: expected %d bay empties, glb has %d" % (BAYS, len(found)))
print("PY: OK")
