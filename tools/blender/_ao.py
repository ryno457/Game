"""Bake ambient occlusion into vertex colours.

This project has no textures — no image files, no UVs on any mesh — so the
usual answer to "make the surfaces better" (a bigger albedo map, a normal map,
an AO map) is not available. What IS available is the vertex colour channel,
which costs no texture memory, needs no UVs, and survives MultiMesh instancing.

Self-occlusion is most of what an AO map buys on a prop this size: the crease
where a strut meets the ground, the inside of a fork, the underside of a lobe.
Baking it per vertex gets that for free at runtime.

Deterministic on purpose, like everything else in the asset pass: the ray
directions come from a golden-angle spiral, not a random generator, so
rebuilding the assets never changes them.
"""
import math
import os

import numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree

GOLDEN = math.pi * (3.0 - math.sqrt(5.0))


def load_sky(path):
    """An equirectangular HDRI as a float array, ready for direction lookup."""
    import bpy
    img = bpy.data.images.load(os.path.abspath(path))
    buf = np.empty(len(img.pixels), dtype=np.float32)
    img.pixels.foreach_get(buf)
    a = buf.reshape(img.size[1], img.size[0], img.channels)[..., :3].copy()
    bpy.data.images.remove(img)
    return a


def sky_lookup(sky, d):
    """Radiance arriving from direction `d`, Blender's equirect convention.

    u = -atan2(y, x) / 2pi + 0.5 and v = atan2(z, hypot(x, y)) / pi + 0.5, which
    is what Cycles' Environment Texture node does. Worth matching exactly rather
    than picking any reasonable-looking mapping: the terrain is lit by this same
    HDRI through Cycles, and an azimuth convention that disagrees would put the
    moon in the north-west for the ground and the south-east for everything
    standing on it.
    """
    h, w = sky.shape[0], sky.shape[1]
    u = -math.atan2(d.y, d.x) / (2.0 * math.pi) + 0.5
    v = math.atan2(d.z, math.hypot(d.x, d.y)) / math.pi + 0.5
    x = min(w - 1, max(0, int(u * w)))
    y = min(h - 1, max(0, int(v * h)))
    return sky[y, x]


def _hemisphere(n, count):
    """`count` cosine-ish weighted directions in the hemisphere about `n`.

    A Fibonacci spiral over the hemisphere, rotated onto the normal. Even
    coverage from a fixed sequence beats a random sample at this ray count —
    with twelve rays, clumping is visible as blotches on a flat face.
    """
    # Any vector not parallel to n gives a usable tangent frame.
    up = Vector((0.0, 0.0, 1.0)) if abs(n.z) < 0.9 else Vector((1.0, 0.0, 0.0))
    t = n.cross(up).normalized()
    b = n.cross(t)
    out = []
    for i in range(count):
        # z from 1 down toward 0 keeps samples off the horizon, where a ray
        # skims the surface and self-hits on its own polygon.
        z = 1.0 - (i + 0.5) / count * 0.92
        r = math.sqrt(max(0.0, 1.0 - z * z))
        a = i * GOLDEN
        out.append((t * (math.cos(a) * r) + b * (math.sin(a) * r) + n * z).normalized())
    return out


def bake_vertex_sky(objs, sky, rays=32, reach=2.4, floor=0.08,
                    unoccluded_materials=(), gain=1.0):
    """Write the light a sky actually delivers into COLOR_0, per vertex.

    bake_vertex_ao answers "how much of the hemisphere can this vertex see",
    as one grey number. This answers "what light arrives here", in colour: each
    ray that escapes is worth the radiance of the sky in the direction it left,
    so a vertex facing the moon is brighter AND warmer than one facing away,
    and a vertex under an overhang gets neither.

    It is the same upgrade the terrain got from bake_sky.py, at vertex
    resolution and without Cycles — the BVH and the hemisphere sampler that
    bake_vertex_ao already needs are the whole cost.

    OCCLUDERS ARE EVERY MESH IN THE MODEL, not just the one being shaded. A
    machine is a dozen separate parts and a hull that does not shade its own
    undercarriage is the thing this is for.

    NORMALISED BY ONE GLOBAL REFERENCE — the irradiance an unoccluded
    upward-facing surface receives — not by each vertex's own hemisphere.
    Dividing a vertex by its own hemisphere was the first attempt and it
    measures the wrong thing: every unoccluded vertex then reads exactly 1.0
    whichever way it points, because `got` and `ref` are the same sum. A test
    sphere under a sky with a moon in it came back perfectly uniform, moonward
    vertex and away-facing vertex both 1.000. With a global divisor the
    moonward side is brighter and warmer and the underside is dark, which is
    the entire point.

    The divisor is that reference's BRIGHTEST CHANNEL, so a lit upward face
    lands at 1.0 in one channel and below it in the others by however much the
    sky is tinted — the same rule bake_sky.py uses, and for the same reason:
    one scalar across three channels throws the tint away.
    """
    if not isinstance(objs, (list, tuple)):
        objs = [objs]

    # SHARED MESH DATA HAS TO BE MADE UNIQUE FIRST.
    #
    # The drone reuses one rotor mesh across four objects and one jaw mesh
    # across two. Baking per object then writes four different results into the
    # same datablock and the last one wins, and any per-object post-processing
    # runs on that datablock once per object — which is how a remap meant to be
    # applied once got applied k^4 to the rotors and k^2 to the jaws, leaving
    # them almost white while the hull was correct. It looked plausible.
    #
    # Instancing is the right call for geometry and the wrong one for baked
    # lighting, because the whole point is that a rotor on the left of the hull
    # is lit differently from one on the right. A few hundred duplicated
    # vertices is a cheap price for that.
    seen = {}
    for o in objs:
        if o.data.name in seen:
            o.data = o.data.copy()
        seen[o.data.name] = True

    # One BVH over every part, in the model's own space.
    verts_all, tris_all = [], []
    for o in objs:
        base = len(verts_all)
        mw = o.matrix_world
        verts_all.extend([mw @ v.co for v in o.data.vertices])
        for poly in o.data.polygons:
            idx = list(poly.vertices)
            for k in range(1, len(idx) - 1):
                tris_all.append((base + idx[0], base + idx[k], base + idx[k + 1]))
    tree = BVHTree.FromPolygons(verts_all, tris_all, all_triangles=True,
                                epsilon=0.0)

    # The reference: what an open, upward-facing surface receives.
    up = Vector((0.0, 0.0, 1.0))
    ref = np.zeros(3, dtype=np.float32)
    ref_dirs = _hemisphere(up, max(64, rays))
    for d in ref_dirs:
        ref += sky_lookup(sky, d)
    ref /= float(len(ref_dirs))
    divisor = float(max(ref.max(), 1e-6))

    means = []
    for obj in objs:
        me = obj.data
        mw = obj.matrix_world
        nrm = mw.to_3x3().inverted_safe().transposed()
        protect = set()
        if unoccluded_materials:
            keep = set(unoccluded_materials)
            for poly in me.polygons:
                if poly.material_index in keep:
                    protect.update(poly.vertices)

        dirs_cache = {}
        out = []
        for i, v in enumerate(me.vertices):
            if i in protect:
                out.append((1.0, 1.0, 1.0))
                continue
            n = (nrm @ Vector(me.vertex_normals[i].vector))
            if n.length_squared < 1e-9:
                out.append((1.0, 1.0, 1.0))
                continue
            n = n.normalized()
            co = mw @ v.co
            origin = co + n * 0.0001
            key = (round(n.x, 3), round(n.y, 3), round(n.z, 3))
            if key not in dirs_cache:
                dirs_cache[key] = _hemisphere(n, rays)
            got = np.zeros(3, dtype=np.float32)
            for d in dirs_cache[key]:
                if tree.ray_cast(origin, d, reach)[0] is None:
                    got += sky_lookup(sky, d)
            got /= float(len(dirs_cache[key]))
            out.append(tuple(np.clip(got / divisor * gain, floor, 1.0)))

        # EVERY EXISTING COLOUR ATTRIBUTE GOES FIRST.
        #
        # The obvious version of this — get("ao") or create it — is wrong on a
        # model that came back through glTF, because the importer names the set
        # `Color`. The bake then wrote a SECOND attribute alongside the old one,
        # the exporter emitted both, and the original stayed active: Godot went
        # on reading the old AO while the new bake rode along as dead weight,
        # and the tool reported success. Found only by listing the attributes
        # afterwards. One attribute in, one attribute out.
        for existing in list(me.color_attributes):
            me.color_attributes.remove(existing)
        attr = me.color_attributes.new("ao", 'FLOAT_COLOR', 'POINT')
        me.color_attributes.active_color = attr
        me.color_attributes.render_color_index = me.color_attributes.find("ao")
        for i, c in enumerate(out):
            attr.data[i].color = (c[0], c[1], c[2], 1.0)
        assert len(me.color_attributes) == 1, \
            "%s ended up with %d colour attributes" % (obj.name,
                                                       len(me.color_attributes))
        means.append(float(np.mean([sum(c) / 3.0 for c in out])) if out else 1.0)
    return sum(means) / max(1, len(means))


def bake_vertex_ao(obj, rays=12, reach=1.6, strength=0.6, floor=0.35,
                   unoccluded_materials=()):
    """Write 1-occlusion into a COLOR_0 attribute on `obj`.

    reach     how far a ray looks for an occluder, in metres. Beyond the size
              of the prop it just costs time.
    strength  how dark a fully occluded vertex gets.
    floor     darkest a vertex may go, so a crease is shaded, not black.
    unoccluded_materials
              material slot indices to leave at full brightness. The glowing
              orbs go here: COLOR_0 multiplies base colour and a light source
              with AO baked into it looks like a dirty bulb.

    Returns the mean occlusion, which is the one number worth asserting on —
    zero means the bake silently did nothing.
    """
    me = obj.data
    verts = [v.co.copy() for v in me.vertices]
    tris = []
    for poly in me.polygons:
        idx = list(poly.vertices)
        for k in range(1, len(idx) - 1):
            tris.append((idx[0], idx[k], idx[k + 1]))
    tree = BVHTree.FromPolygons(verts, tris, all_triangles=True, epsilon=0.0)

    normals = [Vector(me.vertex_normals[i].vector) for i in range(len(me.vertices))]
    protect = set()
    if unoccluded_materials:
        keep = set(unoccluded_materials)
        for poly in me.polygons:
            if poly.material_index in keep:
                protect.update(poly.vertices)

    dirs_cache = {}
    occ = []
    for i, co in enumerate(verts):
        if i in protect:
            occ.append(0.0)
            continue
        n = normals[i]
        if n.length_squared < 1e-9:
            occ.append(0.0)
            continue
        n = n.normalized()
        # Lift off the surface so a ray does not immediately hit the polygon it
        # started on. A tenth of a millimetre is enough and never crosses a real
        # gap at this scale.
        origin = co + n * 0.0001
        key = (round(n.x, 3), round(n.y, 3), round(n.z, 3))
        if key not in dirs_cache:
            dirs_cache[key] = _hemisphere(n, rays)
        hits = 0
        for d in dirs_cache[key]:
            hit = tree.ray_cast(origin, d, reach)
            if hit[0] is not None:
                hits += 1
        occ.append(hits / float(rays))

    attr = me.color_attributes.get("ao")
    if attr is None:
        attr = me.color_attributes.new("ao", 'FLOAT_COLOR', 'POINT')
    me.color_attributes.active_color = attr
    me.color_attributes.render_color_index = me.color_attributes.find("ao")
    for i, o in enumerate(occ):
        shade = max(floor, 1.0 - o * strength)
        attr.data[i].color = (shade, shade, shade, 1.0)

    return sum(occ) / max(1, len(occ))
