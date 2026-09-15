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

from mathutils import Vector
from mathutils.bvhtree import BVHTree

GOLDEN = math.pi * (3.0 - math.sqrt(5.0))


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
