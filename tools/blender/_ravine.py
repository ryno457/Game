"""A coarse stand-in for RavineWall, for the two Blender previews.

The game builds the surround as a noise-displaced ring in ravine_wall.gd. This
is not that: it is a flat-bottomed basin with four sloped sides, built from the
SAME numbers out of biodome_01.json so the silhouette and the values match even
though the rock does not.

The previews exist to check framing and value structure before paying for a
real in-engine frame (tools/screenshot.sh), and neither of those needs the
gullies. What they DO need is for the off-map pixels to be rock at the right
height rather than world background, which is what this gives them.
"""
import bpy


def rgbf(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)) + (1.0,)


def _flat(name, colour, emit=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = colour
    b.inputs["Roughness"].default_value = 1.0
    if emit:
        b.inputs["Emission Color"].default_value = colour
        b.inputs["Emission Strength"].default_value = emit
    return m


def build(rav, cx, cz, z_sign=1.0):
    """Floor plus basin. `z_sign` is -1 where the caller mirrors Godot's Z."""
    hx, hz = cx * 0.5, cz * 0.5
    ox, oz = hx, hz * z_sign
    floor_y = rav["floor_y_m"]
    crest = rav["crest_y_m"]
    gap = rav["floor_width_m"]
    run = rav["rise_run_m"]

    mesh = bpy.data.meshes.new("ravine")
    verts, faces = [], []
    # Three nested rectangles: the chasm floor out to the gap, the top of the
    # wall, and a skirt beyond it that closes the horizon.
    rings = [(0.0, floor_y), (gap, floor_y), (gap + run, crest),
             (rav["extent_m"], crest + 26.0)]
    for s, y in rings:
        for sx, sz in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
            verts.append((ox + sx * (hx + s), oz + sz * (hz + s) * z_sign, y))
    for r in range(len(rings) - 1):
        a, b = r * 4, (r + 1) * 4
        for i in range(4):
            j = (i + 1) % 4
            faces.append((a + i, a + j, b + j, b + i))
    # The chasm bottom under the map itself, so the notches in the outline show
    # rock rather than background.
    n = len(verts)
    for sx, sz in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
        verts.append((ox + sx * hx, oz + sz * hz * z_sign, floor_y))
    faces.append((n, n + 1, n + 2, n + 3))
    mesh.from_pydata(verts, [], faces)
    mesh.update()
    obj = bpy.data.objects.new("ravine", mesh)
    bpy.context.collection.objects.link(obj)
    mesh.materials.append(_flat("ravine_rock", rgbf(rav["rock"])))
    return obj
