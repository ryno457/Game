"""Bake the ambient light a chosen HDRI throws onto the map.

    ~/.cache/blender-venv/bin/python tools/blender/bake_sky.py <hdri> [res] [samples]

    <hdri>  one of the CC0 Poly Haven skies Blender ships — night, city,
            forest, courtyard, interior, studio, sunrise, sunset — or a path to
            any .exr/.hdr, or `game` for one generated from this project's own
            sky (see sky_hdri()).

WHAT THIS IS, NEXT TO THE AO BAKE. bake_ao.py answers "how much of the sky can
this texel see", as one grey number. This answers "what light actually arrives
here", in colour and with direction: a texel tucked under the west side of a
vine is lit by the eastern half of the sky and takes its colour from there.
AO is the uncoloured, undirected special case of it — a white sky, uniform in
every direction.

It is the same kind of bake as the AO one and shares its shape: same saved
scene, same unwrap, same selected-to-active from 1.28 M faces of vine so the
mat occludes the sky it is standing under.

THE COLOUR PASS IS OFF. What is wanted is irradiance — the light landing on the
surface — not light times albedo. Multiplying the ground's own colour back in
would double it, because the shader already has that colour in
detail_colour_tex.

WORLD LIGHT IS `DIRECT` IN CYCLES, which is worth knowing before wiring the
passes: light straight from the background is not "indirect" just because no
lamp emitted it. Measured here rather than assumed — an indirect-only bake of
this scene returns exactly zero.
"""
import os
import re
import sys

import bpy
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _bl import footprint_mask, image_array, script_args           # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BLEND = os.path.join(ROOT, "art", "detail_vines.blend")
FOOTPRINT = os.path.join(ROOT, "textures", "ground_vines_c.png")
LIGHTING = os.path.join(ROOT, "data", "gameplay", "lighting.tres")
TARGET = "bake_target"
CAGE_M = 1.4

# Blender ships these under datafiles/studiolights/world. Their own license.txt
# says: "All HDRIs are licensed as CC0. These were created by Greg Zaal (Poly
# Haven)." So the free HDRIs are already on disk, which is just as well —
# polyhaven.com and every other HDRI host is blocked by this environment's
# egress proxy.
# bpy.utils.resource_path, NOT os.path.dirname(bpy.__file__). The module lives
# at <root>/scripts/modules/bpy and the datafiles at <root>/datafiles, so the
# obvious anchor points two directories too deep — which raised FileNotFound
# only on the branch that lists the built-in skies, i.e. never during the
# `game` runs this was developed against.
STUDIO = os.path.join(bpy.utils.resource_path('LOCAL'), "datafiles",
                      "studiolights", "world")


def sky_hdri(width=512):
    """An equirectangular HDRI of THIS GAME'S sky, built from lighting.tres.

    WHY GENERATE ONE RATHER THAN PICK ONE. Every HDRI in every free library is
    a photograph of somewhere on Earth — a courtyard, a forest, a hotel room.
    This is a sealed biodome at night on another planet, and its sky is four
    colours in a resource file that the game itself renders through
    ProceduralSkyMaterial. Lighting the bake with `sunset.exr` would light this
    ground with Venice.

    So this reproduces the same four-stop gradient Godot's procedural sky uses:
    zenith to horizon above, horizon to nadir below, times sky_energy. The
    result is a real HDRI — float, equirectangular, above 1.0 where the sky is
    bright — and it is the only one of the candidates that matches the light
    the game will actually render.
    """
    src = open(LIGHTING).read()

    def colour(key):
        m = re.search(key + r"\s*=\s*Color\(([^)]*)\)", src)
        assert m, "no %s in %s" % (key, LIGHTING)
        v = [float(x) for x in m.group(1).split(",")]
        return np.array(v[:3], dtype=np.float32)

    energy = float(re.search(r"sky_energy\s*=\s*([\d.]+)", src).group(1))
    top, hor = colour("sky_top"), colour("sky_horizon")
    g_hor, g_bot = colour("ground_horizon"), colour("ground_bottom")

    h = width // 2
    # v runs 0 at the bottom of the image to 1 at the top, which in an
    # equirectangular map is nadir to zenith.
    v = (np.arange(h, dtype=np.float32) + 0.5) / h
    out = np.empty((h, 3), dtype=np.float32)
    up = v >= 0.5
    t = ((v - 0.5) / 0.5)[up][:, None]
    out[up] = hor * (1.0 - t) + top * t
    t = (v[~up] / 0.5)[:, None]
    out[~up] = g_bot * (1.0 - t) + g_hor * t
    img = np.repeat((out * energy)[:, None, :], width, axis=1)

    bl = bpy.data.images.new("game_sky", width, h, alpha=False,
                             float_buffer=True)
    rgba = np.concatenate([img, np.ones((h, width, 1), dtype=np.float32)],
                          axis=2)
    bl.pixels.foreach_set(rgba.ravel())
    path = os.path.join(ROOT, "build", "hdri", "game_sky.exr")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bl.filepath_raw = path
    bl.file_format = 'OPEN_EXR'
    bl.save()
    print("PY: generated %s from %s  (mean %.4f, zenith %s)"
          % (os.path.relpath(path, ROOT), os.path.relpath(LIGHTING, ROOT),
             img.mean(), (top * energy).round(4)))
    return path


def resolve(name):
    if name == "game":
        return sky_hdri()
    if name == "white":
        # NOT A SKY — A CONTROL. A uniform white world makes this bake compute
        # exactly what bake_ao.py computes: cosine-weighted hemisphere
        # visibility, no colour and no direction. The two tools share no code
        # and take different Cycles paths, so agreeing here is real evidence
        # that both are right, and disagreeing localises the fault.
        return "white"
    if os.path.exists(name):
        return os.path.abspath(name)
    p = os.path.join(STUDIO, name + ".exr")
    assert os.path.exists(p), "no HDRI called %r; have: %s" % (
        name, ", ".join(sorted(f[:-4] for f in os.listdir(STUDIO)
                               if f.endswith(".exr"))) + ", game, or a path")
    return p


def _open_reference(low, mat, node, res_x, res_y):
    """What this surface receives with nothing in the way at all."""
    ref = low.copy()
    ref.data = low.data.copy()
    bpy.context.collection.objects.link(ref)
    ref.location.z += 1000.0
    img = bpy.data.images.new("open", res_x, res_y, alpha=False,
                              float_buffer=True)
    node.image = img
    mat.node_tree.nodes.active = node
    bpy.context.scene.render.bake.use_selected_to_active = False
    bpy.ops.object.select_all(action='DESELECT')
    ref.select_set(True)
    bpy.context.view_layer.objects.active = ref
    bpy.ops.object.bake(type='DIFFUSE')
    a = image_array(img)[..., :3]
    lit = a[a.sum(axis=2) > 1e-9]
    bpy.data.images.remove(img)
    bpy.data.objects.remove(ref, do_unlink=True)
    bpy.context.scene.render.bake.use_selected_to_active = True
    # PER CHANNEL, AND THE BRIGHTEST OPEN SURFACE RATHER THAN THE TYPICAL ONE.
    #
    # Two separate mistakes were made here, and the clamp hid both.
    #
    # First this returned one scalar, the median across all three channels.
    # Fine for a white sky, ruinous for a coloured one: this biodome's sky is
    # strongly blue, so its blue irradiance sat well above that median, 74% of
    # the map clipped at 1.0 in blue while red sat low, and the tint the bake
    # exists to carry was flattened by the very step meant to normalise it.
    #
    # Per-channel medians then still clipped 22% of `night.exr`, because the
    # reference is a copy of the TERRAIN, not a flat card, and a sky with a
    # moon in it is strongly directional: a slope tilted toward the moon really
    # does receive more light than level ground, so "the median open surface"
    # is not the ceiling. The 99th percentile is — it is the best-lit open
    # surface this terrain has, which is what the occluded ones are a fraction
    # of.
    return (np.percentile(lit, 99.0, axis=0) if lit.size
            else np.zeros(3, np.float32))


def _retint(norm, open_rgb, mask, low, mat, node, res_x, res_y):
    """Keep this sky's SHADING, swap in the game's COLOUR.

    The two arguments for choosing a sky pull in opposite directions. Colour
    says use the biodome's own, because that is the light the engine renders.
    Form says use a photograph, because a bright region somewhere in the sky is
    what makes a vine cast a soft shadow, and ProceduralSkyMaterial is a smooth
    dome with no bright region anywhere in it.

    Only one of those can be fixed afterwards. This map is per-channel, so a
    tint is a multiply; a flat map has no shading in it to recover. So the
    shading comes from the chosen sky and the colour is corrected here.

    Concretely: open ground currently reads `open_rgb / max(open_rgb)`. Under
    the game's sky it would read the same ratio computed from the game's own
    open-ground irradiance. Multiplying channel-wise by the quotient moves the
    colour and leaves every spatial variation exactly where it was.
    """
    world = bpy.context.scene.world
    bg = world.node_tree.nodes["Background"]
    for link in list(bg.inputs["Color"].links):
        world.node_tree.links.remove(link)
    env = world.node_tree.nodes.new("ShaderNodeTexEnvironment")
    env.image = bpy.data.images.load(sky_hdri())
    world.node_tree.links.new(env.outputs["Color"], bg.inputs["Color"])

    game_rgb = _open_reference(low, mat, node, res_x, res_y)
    assert float(game_rgb.max()) > 1e-9, "the game sky lit nothing"

    # ANCHORED ON THE AVERAGE OVER THE FLOOR, not on open ground.
    #
    # Anchoring on open ground is the more principled choice and it is the
    # wrong one here, because it overshoots what anyone looking at the map
    # would call its colour. Under a sky with a warm moon, shaded texels see
    # proportionally less of the moon and are already bluer than open ground
    # is; correcting the open-ground ratio then pushes the shaded majority
    # past the target. Measured: matching open ground took night's mean tint
    # to 0.50/0.82/1.68 against a target of 0.59/0.90/1.51.
    want = game_rgb / game_rgb.mean()
    have = norm[mask].reshape(-1, 3).mean(axis=0)
    have = have / have.mean()
    gain = want / np.maximum(have, 1e-6)
    out = norm * gain
    # Blue is scaled up by most of a factor of two, so the top of the range has
    # to come back down or the clamp eats it.
    peak = float(np.percentile(out[mask], 99.8))
    if peak > 1.0:
        out /= peak
        gain = gain / peak
    print("PY: retint — floor tint %s -> %s  (gain %s, peak %.3f)"
          % (have.round(3), want.round(3), gain.round(3), peak))
    return np.clip(out, 0.0, 1.0), open_rgb * gain


def main():
    argv = [a for a in script_args()]
    retint = "--retint" in argv
    argv = [a for a in argv if a != "--retint"]
    assert argv, __doc__
    name = argv[0]
    res_x = int(argv[1]) if len(argv) > 1 else 1024
    samples = int(argv[2]) if len(argv) > 2 else 48
    hdri = resolve(name)
    out = os.path.join(ROOT, "build", "hdri",
                       "sky_%s%s.png" % (name, "_retint" if retint else ""))

    bpy.ops.wm.open_mainfile(filepath=BLEND)
    sc = bpy.context.scene
    low = bpy.data.objects.get(TARGET)
    assert low is not None, "no %s in %s" % (TARGET, BLEND)
    sources = [o for o in sc.objects if o.type == 'MESH' and o is not low]
    assert sources, "nothing to cast shade with"

    # THE HDRI IS THE ONLY LIGHT. Any lamp left in the scene would put its own
    # direct light into a bake that is supposed to be pure ambient, and the
    # saved vine scene does carry one.
    for o in [o for o in sc.objects if o.type == 'LIGHT']:
        bpy.data.objects.remove(o, do_unlink=True)
    world = bpy.data.worlds.new("hdri")
    sc.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    if hdri == "white":
        bg.inputs["Color"].default_value = (1.0, 1.0, 1.0, 1.0)
    else:
        env = world.node_tree.nodes.new("ShaderNodeTexEnvironment")
        env.image = bpy.data.images.load(hdri)
        world.node_tree.links.new(env.outputs["Color"], bg.inputs["Color"])

    res_y = int(round(res_x * low.dimensions.y / low.dimensions.x))
    print("PY: %s -> %dx%d at %d samples, %d source objects"
          % (os.path.basename(hdri), res_x, res_y, samples, len(sources)))

    sc.render.engine = 'CYCLES'
    sc.cycles.device = 'CPU'
    sc.cycles.samples = samples
    sc.cycles.use_denoising = False
    sc.render.bake.use_selected_to_active = True
    sc.render.bake.use_cage = False
    sc.render.bake.cage_extrusion = CAGE_M
    sc.render.bake.max_ray_distance = CAGE_M * 2.0
    sc.render.bake.use_pass_direct = True
    sc.render.bake.use_pass_indirect = True
    sc.render.bake.use_pass_color = False

    mat = bpy.data.materials.new("sky_bake")
    mat.use_nodes = True
    low.data.materials.clear()
    low.data.materials.append(mat)
    img = bpy.data.images.new("sky", res_x, res_y, alpha=False,
                              float_buffer=True)
    node = mat.node_tree.nodes.new("ShaderNodeTexImage")
    node.image = img
    mat.node_tree.nodes.active = node

    bpy.ops.object.select_all(action='DESELECT')
    for o in sources:
        o.select_set(True)
    low.select_set(True)
    bpy.context.view_layer.objects.active = low
    bpy.ops.object.bake(type='DIFFUSE')

    a = image_array(img)[..., :3]
    inside = footprint_mask(a.shape[:2], FOOTPRINT)
    m = a[inside]
    assert m.size, "the footprint mask matched nothing"

    # NORMALISED BY WHAT FULLY OPEN GROUND RECEIVES, and that value is MEASURED
    # rather than guessed at.
    #
    # The bake is irradiance in whatever units the HDRI carries — night.exr is
    # a hundredth of city.exr — and the shader wants a fraction. The first
    # version divided by the 99.5th percentile of the map on the reasoning that
    # the brightest half-percent must be open sky. It is not: the vine mat
    # covers the WHOLE floor, so the brightest texel is merely the least
    # shaded one, the divisor came out too small, and the map read 0.690 where
    # the AO bake of the same scene read 0.840. Chasing that gap through
    # resolution (no: 0.840 at 384 too) and AO ray distance (no: 0.828 at 100 m)
    # found nothing, because the fault was in the ruler.
    #
    # So the divisor is a real measurement: the same target, lifted a kilometre
    # clear of every occluder, baked under the same world. Nothing above it,
    # nothing beside it, so what it receives IS open sky.
    open_rgb = _open_reference(low, mat, node, res_x, res_y)
    # Divided by the BRIGHTEST channel of open ground, so the brightest channel
    # of fully lit floor lands at exactly 1.0 and nothing clips. The other two
    # land below it by however much the sky is tinted, which is the tint.
    open_ground = float(open_rgb.max())
    assert open_ground > 1e-6, \
        "open ground received %s — the HDRI lit nothing" % open_rgb.round(5)
    norm = np.clip(a / open_ground, 0.0, 1.0)
    if retint:
        norm, open_rgb = _retint(norm, open_rgb, inside, low, mat, node,
                                 res_x, res_y)
    # OF THE MAP THAT GETS WRITTEN. Taking this off the raw bake reported the
    # sky's own tint and silently ignored the retint, so a run that had just
    # swapped warm for cold printed the warm number.
    tint = norm[inside].reshape(-1, 3).mean(axis=0)
    tint = tint / max(1e-9, tint.mean())

    os.makedirs(os.path.dirname(out), exist_ok=True)
    save = bpy.data.images.new("sky_out", res_x, res_y, alpha=False)
    rgba = np.concatenate(
        [norm.astype(np.float32),
         np.ones((res_y, res_x, 1), dtype=np.float32)], axis=2)
    # foreach_set takes float32 only. The retint multiply promotes to float64
    # and the error it raises — "incorrect sequence item type: d" — names the
    # dtype rather than the cause, so the cast is explicit and stays.
    save.pixels.foreach_set(np.ascontiguousarray(rgba, dtype=np.float32).ravel())
    save.filepath_raw = out
    save.file_format = 'PNG'
    save.save()

    inm = norm[inside]
    clipped = 100.0 * (inm.max(axis=1) >= 0.999).mean()
    print("PY: open ground irradiance %s, divisor %.4f (brightest channel)"
          % (open_rgb.round(5), open_ground))
    print("PY: inside the map — mean %.3f  5th %.3f  below 0.9 %.1f%%  tint %s"
          % (inm.mean(), float(np.percentile(inm, 5)),
             100.0 * (inm.mean(axis=1) < 0.9).mean(), tint.round(3)))
    print("PY:   clipped at 1.0: %.1f%%" % clipped)
    assert inm.mean() < 0.99, \
        "mean %.3f — nothing shaded anything, so the bake missed the sources" \
        % inm.mean()
    # A map that is mostly clipped has thrown away the tint it was baked for.
    assert clipped < 5.0, \
        "%.1f%% of the map is clipped at 1.0 — the divisor is wrong for this " \
        "sky and the tint has been flattened" % clipped
    print("PY: wrote %s" % os.path.relpath(out, ROOT))


main()
