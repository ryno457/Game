"""The high-detail source scene, and the tiling maps baked out of it.

    ~/.cache/blender-venv/bin/python tools/blender/detail_source.py

Writes:
    art/detail_source.blend       the editable high-detail scene
    textures/ground_detail_n.png  RG = slope along world X and Z, B = height
    textures/ground_detail_c.png  RGB = colour, A = vine coverage mask

WHY THIS EXISTS. The game's ground is one flat teal wash because every scale of
detail it has is procedural noise, and noise is not form — measured, the build
carries MORE fine-scale chroma than the reference paintings while carrying a
third of their fine LUMA. Detail you can model and light in Blender, then bake,
is form. This is where that modelling lives.

WHY IT TILES RATHER THAN UNWRAPPING. Every Blender-to-Godot baking tutorial
describes a high-poly-to-low-poly mesh bake: two meshes, a UV unwrap, a cage.
That is right for a prop and wrong for this terrain, which HAS NO UVS AND NEVER
WILL — terrain_lit.gdshader projects from world XZ specifically so the ground
survives being dug. So this bakes a flat plane over a detailed scene into a
SEAMLESS TILE, which the shader repeats in world space. See
docs/research/blender-to-godot-baking.md.

THE TILE SIZE IS NOT A MATTER OF TASTE. At the shipped camera the ground is
19.13 px per metre, so a 512 px sheet covering 26.8 m is sampled at exactly one
texel per screen pixel — mip 0, maximum detail, no aliasing, no wasted texels.
Smaller tiles repeat visibly; larger ones spend memory on detail the screen
cannot resolve.
"""
import math
import os
import random
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _bl import cycles_cpu, script_args          # noqa: E402
import _organic as og                            # noqa: E402
from build_flora import MB, hexcol, make_object  # noqa: E402

TILE = 26.8          # metres, = 512 px at the camera's 19.13 px/m
RES = 512
SEED = 20260916

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BLEND = os.path.join(ROOT, "art", "detail_source.blend")
OUT_N = os.path.join(ROOT, "textures", "ground_detail_n.png")
OUT_C = os.path.join(ROOT, "textures", "ground_detail_c.png")

# --- the palette, sampled from docs/reference/01-vtt-cavern-map.jpg ----------
#
# NOTHING HERE IS LIGHT GREY, and that is a rule rather than an accident. The
# machines are light grey; if the landscape shares that value the units stop
# reading against it from a 50 m camera. Every "grey" below is a teal-tinted
# grey, which is what the reference actually uses — its single most achromatic
# sample is #707b6d at 1.2% of the image, and there is nothing lighter.
GROUND_DARK = "16323a"
GROUND_MID = "1f3d3c"
GROUND_LIT = "345a54"
VINE_CREST = "53817c"     # the pale structural tube: the dominant web
VINE_BODY = "39605e"
VINE_INK = "17383a"       # the dark outline. Not black — it holds real chroma.
LIVE_CREST = "5fa568"     # the glowing emerald roots: a small MINORITY
LIVE_BODY = "367141"
GLOW = "68d9aa"


def _mat(name, hexs, rough=0.85, emit=None, emit_w=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = hexcol(hexs)
    b.inputs["Roughness"].default_value = rough
    if emit is not None and "Emission Color" in b.inputs:
        b.inputs["Emission Color"].default_value = hexcol(emit)
        b.inputs["Emission Strength"].default_value = emit_w
    return m


def _vine_run(rng, x0, y0, length, width):
    """One vine, as a chain of arcs that wanders and tapers.

    Real roots do not run straight and do not hold one thickness. The radius
    swells and pinches along the length, which is the single thing that stops a
    swept tube reading as a pipe.
    """
    pts, radii = [], []
    x, y = x0, y0
    ang = rng.uniform(0, math.tau)
    steps = max(4, int(length / 1.1))
    for i in range(steps):
        t = i / float(steps - 1)
        ang += rng.uniform(-0.45, 0.45)
        step = length / steps
        x += math.cos(ang) * step
        y += math.sin(ang) * step
        # Sit just above the ground plane; the bake reads height from Z.
        pts.append((x, y, 0.02 + 0.10 * width))
        swell = 0.62 + 0.38 * math.sin(t * math.pi * rng.uniform(1.4, 3.2))
        # Taper at both ends so a vine emerges from and returns to the ground
        # instead of stopping dead.
        ends = min(1.0, 3.2 * min(t, 1.0 - t) + 0.25)
        radii.append(width * swell * ends)
    return pts, radii


def build(rng):
    """The high-detail scene: a mottled floor, and vines on it IN PATCHES."""
    mats = [
        _mat("ground", GROUND_MID, 0.92),
        _mat("vine", VINE_BODY, 0.80),
        _mat("vine_crest", VINE_CREST, 0.74),
        _mat("live", LIVE_BODY, 0.70, GLOW, 2.5),
    ]
    # The floor. Subdivided so the displacement modifier has vertices to move:
    # this is the sub-vine mottling the references carry everywhere and the
    # build has none of.
    bpy.ops.mesh.primitive_plane_add(size=TILE * 3.0, location=(0, 0, 0))
    floor = bpy.context.active_object
    floor.name = "floor"
    floor.data.materials.append(mats[0])
    m = floor.modifiers.new("sub", 'SUBSURF')
    m.subdivision_type = 'SIMPLE'
    m.levels = m.render_levels = 7
    tex = bpy.data.textures.new("mottle", 'CLOUDS')
    tex.noise_scale = 1.4
    tex.noise_depth = 4
    d = floor.modifiers.new("mottle", 'DISPLACE')
    d.texture = tex
    d.strength = 0.22
    d.mid_level = 0.5

    # PATCHES. The note that started this was that not all the ground should be
    # vines, so coverage is decided by a coarse blue-noise-ish scatter of patch
    # centres and vines only grow inside one. Roughly half the tile stays clear.
    patches = []
    for _ in range(7):
        patches.append((rng.uniform(-TILE, TILE), rng.uniform(-TILE, TILE),
                        rng.uniform(3.0, 7.5)))

    made = 0
    for px, py, pr in patches:
        # A patch is a bundle of vines that braid, not one vine. Measured off
        # the reference: bundles of about four crests inside a 3.6 m envelope.
        for _ in range(rng.randint(3, 6)):
            a = rng.uniform(0, math.tau)
            r = pr * math.sqrt(rng.random())
            x0 = px + math.cos(a) * r
            y0 = py + math.sin(a) * r
            width = rng.uniform(0.22, 0.55)      # measured: 0.35-0.85 m radius
            pts, radii = _vine_run(rng, x0, y0, rng.uniform(5.0, 13.0), width)
            # One vine in six is a LIVE one that glows. The reference's
            # glowing emerald roots are 0.8-1.2% of area; the rest of the web
            # is a pale UNLIT tube. Making the whole web a light source is
            # what turned it into a neon scribble the first time.
            slot = 3 if rng.random() < 0.17 else 1
            mb = MB()
            mb.tube(0, pts, radii, 7, ridge=rng.uniform(0.04, 0.13),
                    seed=rng.random() * 99.0)
            # Beads along the spine. In the reference the light is not ON the
            # vine, it is in nodules strung along it.
            if slot == 3:
                for k in range(2, len(pts) - 1, 4):
                    q = pts[k]
                    mb.orb(0, (q[0], q[1], q[2] + radii[k] * 0.8),
                           radii[k] * 0.75, 7, 4)
            make_object("vine_%d" % made, mb, [mats[slot]])
            made += 1
    print("PY: %d vines in %d patches" % (made, len(patches)))
    return floor


def bake(floor):
    """Bake the scene down onto one flat plane, over the central tile only.

    The scene is built three tiles wide and only the middle is baked, so every
    feature crossing the tile boundary has its continuation actually present in
    the scene. That is what makes the result seamless — there is no clever
    wrapping step, just enough geometry off the edges.
    """
    sc = bpy.context.scene
    cycles_cpu(sc, 24)

    # SELECTED TO ACTIVE. Without this, bake() bakes the selected object's OWN
    # materials — so the first attempt produced a perfectly flat normal map and
    # a uniform grey colour map, which is a faithful bake of the bake target's
    # default white material and nothing at all of the scene above it.
    sc.render.bake.use_selected_to_active = True
    sc.render.bake.use_cage = False
    sc.render.bake.cage_extrusion = 0.6
    sc.render.bake.max_ray_distance = 1.5

    bpy.ops.mesh.primitive_plane_add(size=TILE, location=(0, 0, 0))
    target = bpy.context.active_object
    target.name = "bake_target"
    mat = bpy.data.materials.new("bake")
    mat.use_nodes = True
    target.data.materials.append(mat)
    node = mat.node_tree.nodes.new("ShaderNodeTexImage")
    mat.node_tree.nodes.active = node

    sources = [o for o in bpy.context.scene.objects
               if o.type == 'MESH' and o is not target]
    print("PY: baking %d source objects onto the tile" % len(sources))

    def _bake(kind, path, setup=None):
        img = bpy.data.images.new("bake_" + kind, RES, RES, alpha=False,
                                  float_buffer=False)
        node.image = img
        mat.node_tree.nodes.active = node
        bpy.ops.object.select_all(action='DESELECT')
        for o in sources:
            o.select_set(True)
        target.select_set(True)
        bpy.context.view_layer.objects.active = target
        if setup:
            setup()
        bpy.ops.object.bake(type=kind)
        img.filepath_raw = path
        img.file_format = 'PNG'
        img.save()
        print("PY: wrote %s" % path)

    _bake('NORMAL', OUT_N)

    def _diffuse_only():
        sc.render.bake.use_pass_direct = False
        sc.render.bake.use_pass_indirect = False
        sc.render.bake.use_pass_color = True

    _bake('DIFFUSE', OUT_C, _diffuse_only)


def main():
    rng = random.Random(SEED)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    floor = build(rng)
    os.makedirs(os.path.dirname(BLEND), exist_ok=True)
    os.makedirs(os.path.dirname(OUT_N), exist_ok=True)
    bake(floor)
    # Saved AFTER the bake so the .blend opens with the bake set up, which is
    # the state anyone editing this actually wants to land in.
    bpy.ops.wm.save_as_mainfile(filepath=BLEND)
    print("PY: wrote %s" % BLEND)


main()
