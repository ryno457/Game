"""Bake ambient occlusion from the high-detail source onto the whole map.

    ~/.cache/blender-venv/bin/python tools/blender/bake_ao.py [res_x] [samples]

WHY THIS DID NOT EXIST. detail_source.py bakes three maps off the vine scene —
normal, colour and depth — and no occlusion. The project does have AO in two
other places, and neither covers this one:

  tools/blender/_ao.py         bakes AO into VERTEX COLOURS on the props. Its
                               own docstring says it exists because "this
                               project has no textures — no image files, no UVs
                               on any mesh". That stopped being true when the
                               terrain got a real unwrap.
  TerrainBuilder.bake_shade()  sweeps the HEIGHTFIELD, one value per metre, and
                               packs AO into the R channel of the shade map.

So the ground is occluded by the terrain's own shape and by nothing else. The
vine mat — 1.28 million faces of it, lying directly on that ground — casts no
contact darkening at all, which is exactly the cue that stops a mat looking
like a decal printed on the floor.

This bakes that missing term off the SAME saved scene the other three maps came
from, so it lines up with them texel for texel and costs nothing at runtime:
the shader already has an AO term to multiply it into.

IT IS A LIGHT INTEGRATION, unlike its three siblings. detail_source.py runs the
normal and colour bakes at 4 samples and says so — they are geometric and more
samples would be identical output for minutes more CPU. AO is not: it is a
visibility integral, and 4 samples of it is noise.
"""
import os
import sys

import bpy
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _bl import script_args                                      # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BLEND = os.path.join(ROOT, "art", "detail_vines.blend")
OUT = os.path.join(ROOT, "textures", "ground_vines_ao.png")
# The colour bake, used only as a silhouette. Same scene, same unwrap, so the
# texels it covers are the texels this one covers.
FOOTPRINT = os.path.join(ROOT, "textures", "ground_vines_c.png")
TARGET = "bake_target"
# The same cage detail_source.py bakes the other three maps through, so the
# rays that find the vines here are the rays that found them there.
CAGE_M = 1.4


def footprint_mask(shape):
    """True where the biodome floor is, False in the off-map void."""
    img = bpy.data.images.load(FOOTPRINT)
    buf = np.empty(len(img.pixels), dtype=np.float32)
    img.pixels.foreach_get(buf)
    c = buf.reshape(img.size[1], img.size[0], img.channels)[..., :3].mean(axis=2)
    bpy.data.images.remove(img)
    if c.shape != shape:
        # Nearest-neighbour, because this is a mask and a filtered edge would
        # blend void into floor.
        yi = (np.arange(shape[0]) * c.shape[0] // shape[0]).clip(0, c.shape[0] - 1)
        xi = (np.arange(shape[1]) * c.shape[1] // shape[1]).clip(0, c.shape[1] - 1)
        c = c[yi][:, xi]
    return c > 0.02


def main():
    argv = script_args()
    res_x = int(argv[0]) if argv else 2048
    samples = int(argv[1]) if len(argv) > 1 else 64

    bpy.ops.wm.open_mainfile(filepath=BLEND)
    sc = bpy.context.scene
    low = bpy.data.objects.get(TARGET)
    assert low is not None, "no %s in %s — has the bake scene changed?" % (TARGET, BLEND)
    sources = [o for o in sc.objects if o.type == 'MESH' and o is not low]
    faces = sum(len(o.data.polygons) for o in sources)
    assert sources, "nothing to occlude with"

    res_y = int(round(res_x * low.dimensions.y / low.dimensions.x))
    print("PY: %d source objects, %d faces -> %dx%d at %d samples"
          % (len(sources), faces, res_x, res_y, samples))

    sc.render.engine = 'CYCLES'
    sc.cycles.device = 'CPU'
    sc.cycles.samples = samples
    sc.cycles.use_denoising = False
    sc.render.bake.use_selected_to_active = True
    sc.render.bake.use_cage = False
    sc.render.bake.cage_extrusion = CAGE_M
    sc.render.bake.max_ray_distance = CAGE_M * 2.0

    mat = bpy.data.materials.new("ao_bake")
    mat.use_nodes = True
    low.data.materials.clear()
    low.data.materials.append(mat)
    img = bpy.data.images.new("ao", res_x, res_y, alpha=False, float_buffer=False)
    node = mat.node_tree.nodes.new("ShaderNodeTexImage")
    node.image = img
    mat.node_tree.nodes.active = node

    bpy.ops.object.select_all(action='DESELECT')
    for o in sources:
        o.select_set(True)
    low.select_set(True)
    bpy.context.view_layer.objects.active = low
    bpy.ops.object.bake(type='AO')

    buf = np.empty(len(img.pixels), dtype=np.float32)
    img.pixels.foreach_get(buf)
    a = buf.reshape(res_y, res_x, img.channels)[..., 0]

    img.filepath_raw = OUT
    img.file_format = 'PNG'
    img.save()

    # MEASURED INSIDE THE MAP ONLY.
    #
    # Everything outside the biodome's silhouette is untouched by the bake and
    # stays black, and black reads as fully occluded. The first version of this
    # averaged that in and reported an AO mean of 0.699 on a map whose interior
    # is almost white — a third of the image is off-map, and the number was
    # mostly measuring how much of the texture is empty. An assertion that
    # passes because the margin is black would pass just as happily on a bake
    # that found no geometry at all, which is the exact failure it is for.
    inside = footprint_mask(a.shape)
    m = a[inside]
    print("PY: inside the map footprint (%d of %d texels, %.0f%% of the image)"
          % (inside.sum(), a.size, 100.0 * inside.mean()))
    print("PY:   AO mean %.3f  min %.3f  5th %.3f  fraction under 0.9 %.1f%%"
          % (m.mean(), m.min(), float(np.percentile(m, 5)),
             100.0 * (m < 0.9).mean()))
    assert m.mean() < 0.98, \
        "AO came back at %.3f inside the map — essentially white, so nothing " \
        "occluded anything and the bake did not see the sources" % m.mean()
    assert (m < 0.9).mean() > 0.05, \
        "only %.1f%% of the MAP is occluded at all; a vine mat over the whole " \
        "floor should shade far more than that" % (100.0 * (m < 0.9).mean())
    print("PY: wrote %s" % OUT)


main()
