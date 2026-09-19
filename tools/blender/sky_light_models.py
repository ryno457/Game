"""Bake the sky's light into every model's vertex colours.

    ~/.cache/blender-venv/bin/python tools/blender/sky_light_models.py \
        [sky] [rays] [model ...]

    sky   one of Blender's CC0 Poly Haven skies (night, forest, ...), or a path
          to any .exr/.hdr. Defaults to `night`, which is what the terrain
          bake uses.
    rays  hemisphere samples per vertex. 32 is enough for a smooth result.

Options:
    --target-mean X   scale each model so its mean lands at X. Default: keep
                      whatever mean the model already had, and use 0.85 for a
                      model that had no vertex colours.
    --raw             no scaling at all — the physically correct irradiance.

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
    argv = script_args()
    sky_name = argv[0] if argv else "night"
    rays = int(argv[1]) if len(argv) > 1 else 32
    raw = "--raw" in argv
    target = None
    if "--target-mean" in argv:
        target = float(argv[argv.index("--target-mean") + 1])
    wanted = [a for a in argv[2:]
              if not a.startswith("--") and a != str(target)]
    sky = load_sky(resolve(sky_name))

    paths = sorted(glob.glob(os.path.join(MODELS, "*.glb")))
    if wanted:
        paths = [p for p in paths
                 if os.path.basename(p)[:-4] in wanted]
    print("SENTINEL — sky light into %d models, %s at %d rays\n"
          % (len(paths), sky_name, rays))
    print("  %-18s %6s %7s %7s %7s %6s %s"
          % ("model", "verts", "was", "raw", "mean", "spread", "tint"))

    import numpy as np
    for p in paths:
        bpy.ops.wm.read_factory_settings(use_empty=True)
        bpy.ops.import_scene.gltf(filepath=p)
        before = shape()
        objs = [o for o in bpy.data.objects if o.type == 'MESH']
        if not objs:
            print("  %-18s no meshes, skipped" % os.path.basename(p)[:-4])
            continue

        # What it looked like before, so the scaling has something to match.
        was = []
        for o in objs:
            # By whatever name it has: glTF round-trips call it `Color`.
            prev = o.data.color_attributes.active_color
            if prev is None and len(o.data.color_attributes):
                prev = o.data.color_attributes[0]
            if prev is None:
                continue
            n = (len(o.data.vertices) if prev.domain == 'POINT'
                 else len(o.data.loops))
            buf = np.empty(n * 4, dtype=np.float32)
            prev.data.foreach_get("color", buf)
            was.append(buf.reshape(-1, 4)[:, :3])
        had = float(np.concatenate(was).mean()) if was else None

        bake_vertex_sky(objs, sky, rays=rays, reach=2.4,
                        unoccluded_materials=emissive_slots(objs))

        cols = []
        for o in objs:
            attr = o.data.color_attributes.get("ao")
            buf = np.empty(len(o.data.vertices) * 4, dtype=np.float32)
            attr.data.foreach_get("color", buf)
            cols.append(buf.reshape(-1, 4)[:, :3])
        a = np.concatenate(cols)
        got = float(a.mean())

        want = target if target is not None else (
            had if had is not None else 0.85)
        # TOWARD WHITE, NOT A MULTIPLY.
        #
        # Multiplying by want/got was the first attempt and undershoots: the
        # gain is above 1 for every model, so the brightest vertices clip at
        # 1.0 and drag the mean back down — rock_spire asked for 0.921 and
        # landed at 0.711. `1 - (1-x)*k` is the ordinary AO strength control:
        # it maps [0,1] onto [1-k,1], cannot clip, and keeps the relative
        # shading exactly. k solves 1 - k(1 - got) = want.
        k = 1.0 if raw else (1.0 - want) / max(1e-6, 1.0 - got)
        if not raw and abs(k - 1.0) > 0.001:
            for o in objs:
                attr = o.data.color_attributes.get("ao")
                n = len(o.data.vertices)
                buf = np.empty(n * 4, dtype=np.float32)
                attr.data.foreach_get("color", buf)
                q = buf.reshape(-1, 4)
                q[:, :3] = np.clip(1.0 - (1.0 - q[:, :3]) * k, 0.0, 1.0)
                attr.data.foreach_set("color", q.ravel())
            cols = []
            for o in objs:
                attr = o.data.color_attributes.get("ao")
                buf = np.empty(len(o.data.vertices) * 4, dtype=np.float32)
                attr.data.foreach_get("color", buf)
                cols.append(buf.reshape(-1, 4)[:, :3])
            a = np.concatenate(cols)
        tint = a.mean(axis=0) / max(1e-6, a.mean())
        # THE TOOL'S OWN CONTRACT: it says it lands the mean on `want`, so it
        # checks. A remap that quietly misses its target is how a "drop-in"
        # upgrade turns out to have changed every asset's brightness.
        if not raw:
            assert abs(float(a.mean()) - want) < 0.01, (
                "%s asked for a mean of %.3f and produced %.3f (raw %.3f, "
                "k %.3f)" % (os.path.basename(p)[:-4], want, a.mean(), got, k))

        export_glb(p)
        bpy.ops.wm.read_factory_settings(use_empty=True)
        bpy.ops.import_scene.gltf(filepath=p)
        after = shape()
        for o in [x for x in bpy.data.objects if x.type == 'MESH']:
            assert len(o.data.color_attributes) == 1, (
                "%s exported %d colour sets; Godot reads one and the rest are "
                "dead weight" % (o.name, len(o.data.color_attributes)))
        assert before == after, (
            "%s changed shape on the round trip:\n  before %s\n  after  %s"
            % (os.path.basename(p), before, after))

        print("  %-18s %6d %7s %7.3f %7.3f %6.3f  %s"
              % (os.path.basename(p)[:-4], before["verts"],
                 "%.3f" % had if had is not None else "none",
                 got, a.mean(), a.std(), tint.round(3)))

    print("\nEvery model round-tripped with its shape unchanged.")


main()
