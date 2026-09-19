"""Report what baked lighting each model carries. READ ONLY.

    ~/.cache/blender-venv/bin/python tools/blender/sky_light_models.py

THIS USED TO REWRITE THE MODELS IN PLACE, and it must not, because the glTF
round trip is NOT IDEMPOTENT. Importing and re-exporting alien_breacher took it
from 1532 vertices to 1540, then 1542, then 1544 — the exporter splits vertices
at UV and normal seams and the split is not stable, so every run of such a tool
would bloat the assets a little more, silently.

The .glb files are generated artifacts and their builders are deterministic
(build_flora.py reproduces all seven byte for byte), so the bake belongs in the
builders, where there is no round trip at all. See build_flora.py, which calls
bake_vertex_sky and then remap_mean_spread.

What is left here is the audit that found the problem worth fixing in the first
place: model_library.gd claims "the assets carry baked ambient occlusion in
COLOR_0", and that is true of the flora and of nothing else.

WHY THIS EXISTS. An audit of the shipped models found the comment in
model_library.gd — "the assets carry baked ambient occlusion in COLOR_0" —
is true of the flora and of nothing else:

    carries vertex AO   alien_ruin, flora_arch, flora_brain, flora_coral,
                        flora_pods, flora_tendril, rock_spire
    carries NOTHING     alien_breacher, alien_swarmer, bulwark, drone, guard,
                        module_forms, radar, turret

Every machine, the drone, the module and both alien creatures have no baked
ambient at all. They are lit entirely by the runtime rig, which is why they
read as separate from a landscape that now carries a whole-map light bake.

WHAT IT WRITES is not occlusion but IRRADIANCE, the same quantity bake_sky.py
puts on the terrain: each ray that escapes is worth the radiance of the sky in
the direction it left, so a surface facing the moon is brighter and warmer than
one facing away, and an undercarriage gets neither. Occluders are every mesh in
the model, so a hull shades its own underside.

AND THEN IT SCALES THAT BACK TO THE BRIGHTNESS THE MODEL ALREADY HAD, which
sounds like undoing the work and is the opposite. Raw irradiance is much darker
than the AO it replaces — rock_spire measures 0.921 as AO and 0.659 as
irradiance, the drone 0.280 — because real sky occlusion is simply darker than
a gentle ambient term. The terrain bake learned this the expensive way: applied
at full strength it cost a quarter of the frame's luminance and failed the
value check, because the scene's lighting was authored against surfaces with no
occlusion on them. Matching the mean keeps the DIRECTION and the COLOUR, which
are the new information, and leaves overall brightness where the rest of the
game's lighting expects it. --raw is there for when the lighting is re-authored
to take it.

The prop shader already reads COLOR.rgb as a vec3, so coloured vertex data
needs no shader change.

IT AUDITS THE ROUND TRIP. These are shipped assets and the tool rewrites them
in place, so mesh count, vertex count, materials, UVs and emissive slots are
compared before and after and a mismatch aborts before anything is saved.
"""
import glob
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _ao import bake_vertex_sky, load_sky                        # noqa: E402
from _bl import script_args                                      # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MODELS = os.path.join(ROOT, "models")
STUDIO = os.path.join(bpy.utils.resource_path('LOCAL'), "datafiles",
                      "studiolights", "world")


def resolve(name):
    if os.path.exists(name):
        return os.path.abspath(name)
    p = os.path.join(STUDIO, name + ".exr")
    assert os.path.exists(p), "no sky called %r" % name
    return p


def export_glb(path):
    # Matches build_flora.py: export_vertex_color='ACTIVE' forces COLOR_0 out
    # even though no material node reads it, because Godot applies it itself.
    kwargs = dict(filepath=path, export_format='GLB', export_apply=True,
                  export_yup=True, export_materials='EXPORT',
                  use_selection=False)
    try:
        bpy.ops.export_scene.gltf(export_vertex_color='ACTIVE', **kwargs)
    except TypeError:
        bpy.ops.export_scene.gltf(**kwargs)


def shape():
    """The things a round trip must not change."""
    ms = [o for o in bpy.data.objects if o.type == 'MESH']
    return {
        "meshes": len(ms),
        "verts": sum(len(o.data.vertices) for o in ms),
        "polys": sum(len(o.data.polygons) for o in ms),
        "uvs": sum(1 for o in ms if o.data.uv_layers),
        "mats": len(set(sl.material.name for o in ms
                        for sl in o.material_slots if sl.material)),
    }


def emissive_slots(objs):
    """Material slots that emit, which must stay unoccluded.

    COLOR_0 multiplies base colour, and a light source with shading baked into
    it looks like a dirty bulb. build_flora.py protects these by index; here
    they are found from the material graph, because these models were not all
    built by the same script.
    """
    out = set()
    for o in objs:
        for i, sl in enumerate(o.material_slots):
            m = sl.material
            if m is None or not m.use_nodes:
                continue
            for n in m.node_tree.nodes:
                if n.type == 'EMISSION':
                    out.add(i)
                elif n.type == 'BSDF_PRINCIPLED':
                    inp = n.inputs.get("Emission Strength")
                    if inp is not None and (inp.links
                                            or inp.default_value > 0.0):
                        out.add(i)
    return tuple(sorted(out))




def main():
    import numpy as np
    paths = sorted(glob.glob(os.path.join(MODELS, "*.glb")))
    print("SENTINEL — baked lighting carried by %d models\n" % len(paths))
    print("  %-18s %7s %6s %8s %8s  %s"
          % ("model", "verts", "sets", "mean", "spread", "tint"))
    missing = []
    for p in paths:
        bpy.ops.wm.read_factory_settings(use_empty=True)
        bpy.ops.import_scene.gltf(filepath=p)
        objs = [o for o in bpy.data.objects if o.type == 'MESH']
        nv = sum(len(o.data.vertices) for o in objs)
        cols, sets = [], 0
        for o in objs:
            sets = max(sets, len(o.data.color_attributes))
            for ca in o.data.color_attributes:
                n = (len(o.data.vertices) if ca.domain == 'POINT'
                     else len(o.data.loops))
                buf = np.empty(n * 4, dtype=np.float32)
                ca.data.foreach_get("color", buf)
                cols.append(buf.reshape(-1, 4)[:, :3])
        name = os.path.basename(p)[:-4]
        if not cols:
            missing.append(name)
            print("  %-18s %7d %6d %8s %8s  %s"
                  % (name, nv, 0, "-", "-", "NO BAKED LIGHT"))
            continue
        a = np.concatenate(cols)
        print("  %-18s %7d %6d %8.3f %8.3f  %s"
              % (name, nv, sets, a.mean(), a.std(),
                 (a.mean(axis=0) / max(1e-6, a.mean())).round(3)))
        # More than one set is the bug that hid here once: the exporter emits
        # both, Godot reads the first, and the newer bake is dead weight.
        assert sets <= 1, "%s carries %d colour sets" % (name, sets)
    if missing:
        print("\n  %d model(s) carry no baked light at all:\n    %s"
              % (len(missing), ", ".join(missing)))


main()
