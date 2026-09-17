"""High-detail baked maps for the machines.

    ~/.cache/blender-venv/bin/python tools/blender/bake_machines.py [res] [model...]

Writes, per model:
    textures/machine_<name>_n.png    tangent-space normal
    textures/machine_<name>_ao.png   ambient occlusion
    models/<name>.glb                re-exported WITH the UVs the bake needs

WHY THE MACHINES NEED THIS AND THE LANDSCAPE DID NOT. The ground got its detail
from modelled vines — organic shapes at metre scale. A machine's detail is the
opposite kind: panel seams, bevelled edges, the small catch of light along a
chamfer. That reads as MANUFACTURED, which is the whole point of the machines
being visually separate from the alien landscape, and none of it exists in a
528-triangle procedural hull.

THE TECHNIQUE is the standard mid-poly bevel bake. The high-poly is the low-poly
with a Bevel modifier and a subdivision: no second model is authored, because
the detail wanted here IS the edge treatment. Bevelled edges bake to a normal
map as a bright catch along every seam, which is exactly what a machined surface
does under a light and what a hard-edged procedural hull cannot do.

THE MODELS HAVE NO UVS. They are built procedurally with vertex colours only, so
this unwraps them first — smart-projected, packed across all of a model's meshes
into one atlas, and re-exported. They DO already carry tangents, which a normal
map needs and which would otherwise have to be generated at import.
"""
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _bl import cycles_cpu, script_args          # noqa: E402

argv = script_args()
RES = int(argv[0]) if argv else 512
MODELS = argv[1:] if len(argv) > 1 else ["module_forms", "drone", "guard"]

## Models whose meshes are mutually exclusive ALTERNATES rather than parts of
## one object. Baking their AO together is meaningless: they overlap, so they
## occlude each other in a configuration the game never shows.
ALTERNATES = {"module_forms"}

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
MODEL_DIR = os.path.join(ROOT, "models")
TEX_DIR = os.path.join(ROOT, "textures")

# Bevel width in metres. A machine part is 0.8-4.8 m across, so 12 mm is a
# chamfer you would actually machine — big enough to catch light at the RTS
# camera, small enough not to round the silhouette.
BEVEL_M = 0.012
BEVEL_SEGMENTS = 2


def _clear():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def _meshes():
    return [o for o in bpy.context.scene.objects if o.type == 'MESH']


def unwrap(objs):
    """Smart-project every mesh of a model into ONE shared atlas.

    Multi-object edit mode packs the islands across all selected objects, which
    is what keeps it to one texture per model rather than one per part.
    """
    bpy.ops.object.select_all(action='DESELECT')
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    # island_margin is in UV units, so 0.02 is ten pixels at 512 — per island.
    # The module packs into roughly a hundred islands, and at that margin the
    # gutters ate 95% of the atlas: the bake was correct and almost all of the
    # texture was empty black. A third of a pixel is enough to stop bilinear
    # bleed between neighbours at this resolution.
    bpy.ops.uv.smart_project(angle_limit=1.15, island_margin=0.0015)
    # Then pack properly. smart_project's own packing does not scale islands up
    # to fill, so this is what actually buys the resolution back.
    bpy.ops.uv.select_all(action='SELECT')
    bpy.ops.uv.pack_islands(rotate=True, margin=0.0015, scale=True)
    bpy.ops.object.mode_set(mode='OBJECT')


def high_poly(objs):
    """A bevelled, subdivided copy of each mesh, to bake down from."""
    highs = []
    for o in objs:
        bpy.ops.object.select_all(action='DESELECT')
        o.select_set(True)
        bpy.context.view_layer.objects.active = o
        bpy.ops.object.duplicate()
        h = bpy.context.active_object
        h.name = o.name + "_high"
        b = h.modifiers.new("bevel", 'BEVEL')
        b.width = BEVEL_M
        b.segments = BEVEL_SEGMENTS
        b.limit_method = 'ANGLE'
        b.angle_limit = 0.52          # 30 degrees: real edges, not curvature
        sub = h.modifiers.new("sub", 'SUBSURF')
        sub.subdivision_type = 'SIMPLE'
        sub.levels = sub.render_levels = 1
        highs.append(h)
    return highs


def bake_model(name, res):
    path = os.path.join(MODEL_DIR, name + ".glb")
    if not os.path.exists(path):
        print("PY: no model %s" % path)
        return False
    _clear()
    bpy.ops.import_scene.gltf(filepath=path)
    objs = _meshes()
    if not objs:
        print("PY: %s has no meshes" % name)
        return False

    unwrap(objs)
    highs = high_poly(objs)

    sc = bpy.context.scene
    cycles_cpu(sc, 8)
    sc.render.bake.use_selected_to_active = True
    sc.render.bake.use_cage = False
    # The cage only has to clear the bevel, which is millimetres.
    sc.render.bake.cage_extrusion = 0.05
    sc.render.bake.max_ray_distance = 0.12

    # One image for the model; every low-poly part points its material at it.
    cache = {}

    def _run(kind, suffix, setup=None, only=None, append=False):
        key = "%s_%s" % (name, suffix)
        if append and key in cache:
            img = cache[key]
        else:
            img = bpy.data.images.new(key, res, res, alpha=False,
                                      float_buffer=False)
            cache[key] = img
        nodes = []
        for o in (only if only else objs):
            for slot in o.material_slots:
                m = slot.material
                if m is None:
                    continue
                m.use_nodes = True
                n = m.node_tree.nodes.new("ShaderNodeTexImage")
                n.image = img
                m.node_tree.nodes.active = n
                nodes.append((m, n))
        bpy.ops.object.select_all(action='DESELECT')
        if sc.render.bake.use_selected_to_active:
            for hp in highs:
                hp.select_set(True)
        targets = only if only else objs
        for o in targets:
            o.select_set(True)
        bpy.context.view_layer.objects.active = targets[0]
        if setup:
            setup()
        bpy.ops.object.bake(type=kind)
        out = os.path.join(TEX_DIR, "machine_%s_%s.png" % (name, suffix))
        img.filepath_raw = out
        img.file_format = 'PNG'
        img.save()
        print("PY: wrote %s" % out)
        for m, n in nodes:
            m.node_tree.nodes.remove(n)

    _run('NORMAL', "n")

    # AO is baked from the LOW-POLY ALONE, with the high-poly hidden.
    #
    # Baked selected-to-active like the normal map it came out at 0.004 — near
    # black everywhere. The high-poly is a bevelled copy sitting in exactly the
    # same space as the low-poly, so every occlusion ray leaves a surface and
    # immediately hits its own twin a millimetre away. Ninety-nine per cent
    # occluded is the arithmetically correct answer to the question that was
    # asked, and the wrong question.
    #
    # What is wanted is the module's own self-shadowing — under the bays, in
    # the dock recesses, beneath the deck overhang — and that lives in the
    # low-poly shape. The bevels contribute nothing to occlusion at millimetre
    # width regardless.
    for hp in highs:
        hp.hide_render = True
    sc.render.bake.use_selected_to_active = False
    if name in ALTERNATES:
        # module_forms.glb holds all three growth forms OVERLAPPING at the
        # origin, and the game spawns exactly one of them (ModelLibrary.spawn's
        # `keep` argument exists for precisely this). Baked together they
        # occlude each other completely and the AO came out at 0.063 — a
        # correct answer about a configuration that never exists in the game.
        #
        # So each form is baked with the others hidden. They share one atlas
        # because smart_project packed them into disjoint islands, so the three
        # passes write to different parts of the same image and no pass
        # overwrites another.
        for keep in objs:
            for o in objs:
                o.hide_render = o is not keep
            _run('AO', "ao", only=[keep], append=keep is not objs[0])
        for o in objs:
            o.hide_render = False
    else:
        _run('AO', "ao")
    sc.render.bake.use_selected_to_active = True
    for hp in highs:
        hp.hide_render = False

    # Drop the high-poly and re-export the low-poly, now carrying UVs.
    bpy.ops.object.select_all(action='DESELECT')
    for hp in highs:
        hp.select_set(True)
    bpy.ops.object.delete()
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.export_scene.gltf(filepath=path, export_format='GLB',
                              use_selection=True, export_apply=True,
                              export_yup=True, export_tangents=True,
                              export_normals=True)
    print("PY: re-exported %s with UVs" % path)
    return True


def main():
    os.makedirs(TEX_DIR, exist_ok=True)
    ok = 0
    for name in MODELS:
        if bake_model(name, RES):
            ok += 1
    print("PY: baked %d of %d machine models" % (ok, len(MODELS)))


main()
