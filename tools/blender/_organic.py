"""Organic mesh primitives for the biodome dressing.

The machine scripts build everything from boxes, prisms and extruded profiles,
which is right for machines and useless for a coral reef. These are the shapes
the biodome needs — tubes that follow a curve, spheres, and lumpy blobs — built
the same way: explicit vertex and triangle lists, so the triangle count is known
exactly before export and can be asserted against the exported glTF afterwards.

Everything is deterministic. The "random" wobble is a hash of the vertex index,
not a random call, so rebuilding the assets never changes them.
"""
import math

TAU = math.tau


def _n(a, b=0.0, c=0.0):
    """Deterministic pseudo-noise in [-1, 1]. Same inputs, same value, always."""
    s = math.sin(a * 12.9898 + b * 78.233 + c * 37.719) * 43758.5453
    return (s - math.floor(s)) * 2.0 - 1.0


def lerp3(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def arc(start, end, rise, steps, bow=0.0):
    """Points along a shallow arch from `start` to `end`, peaking `rise` above.

    `bow` pushes the middle sideways, which is what stops three parallel struts
    reading as a drawn-with-a-compass rainbow.
    """
    pts = []
    for i in range(steps):
        t = i / (steps - 1)
        p = lerp3(start, end, t)
        h = math.sin(t * math.pi)
        pts.append((p[0] + bow * h, p[1], p[2] + rise * h))
    return pts


def _frames(points):
    """A up/right pair per point, so a ring can be laid perpendicular to the
    curve. Parallel-transported rather than recomputed from scratch each step,
    which is what stops the tube twisting where the curve turns."""
    up = (0.0, 0.0, 1.0)
    out = []
    ref = None
    for i, p in enumerate(points):
        nxt = points[min(i + 1, len(points) - 1)]
        prv = points[max(i - 1, 0)]
        d = [nxt[k] - prv[k] for k in range(3)]
        L = math.sqrt(sum(c * c for c in d)) or 1.0
        d = [c / L for c in d]
        a = up if abs(d[2]) < 0.9 else (1.0, 0.0, 0.0)
        r = [d[1] * a[2] - d[2] * a[1], d[2] * a[0] - d[0] * a[2], d[0] * a[1] - d[1] * a[0]]
        L = math.sqrt(sum(c * c for c in r)) or 1.0
        r = [c / L for c in r]
        if ref is not None and sum(r[k] * ref[k] for k in range(3)) < 0.0:
            r = [-c for c in r]
        ref = r
        u = [d[1] * r[2] - d[2] * r[1], d[2] * r[0] - d[0] * r[2], d[0] * r[1] - d[1] * r[0]]
        out.append((r, u))
    return out


def tube(points, radii, sides=7, caps=True, ridge=0.0, seed=0.0):
    """A tube swept along `points`. Tris: sides*2*(n-1) + (2*sides-4 if caps).

    `ridge` alternates the ring radius vertex by vertex, which is how a smooth
    sausage becomes the ribbed, segmented thing a tendril needs to look grown
    rather than extruded.
    """
    n = len(points)
    if isinstance(radii, (int, float)):
        radii = [float(radii)] * n
    frames = _frames(points)
    v = []
    for i, p in enumerate(points):
        r, u = frames[i]
        for j in range(sides):
            a = j * TAU / sides
            rad = radii[i] * (1.0 + ridge * (1.0 if j % 2 == 0 else -1.0))
            rad *= 1.0 + 0.06 * _n(i * 1.7 + seed, j * 0.9)
            c, s = math.cos(a) * rad, math.sin(a) * rad
            v.append((p[0] + r[0] * c + u[0] * s,
                      p[1] + r[1] * c + u[1] * s,
                      p[2] + r[2] * c + u[2] * s))
    t = []
    for i in range(n - 1):
        b0, b1 = i * sides, (i + 1) * sides
        for j in range(sides):
            k = (j + 1) % sides
            t += [(b0 + j, b0 + k, b1 + k), (b0 + j, b1 + k, b1 + j)]
    if caps:
        for j in range(1, sides - 1):
            t.append((0, j + 1, j))
        b = (n - 1) * sides
        for j in range(1, sides - 1):
            t.append((b, b + j, b + j + 1))
    return v, t


def sphere(r=1.0, segs=8, rings=5, squash=1.0, lumps=0.0, seed=0.0):
    """UV sphere. Tris: segs * 2 + segs * 2 * (rings - 2).

    `lumps` pushes vertices in and out deterministically — a perfect sphere
    reads as a beach ball, and nothing in that image is a beach ball.
    """
    v = [(0.0, 0.0, r * squash)]
    for i in range(1, rings - 1):
        phi = math.pi * i / (rings - 1)
        for j in range(segs):
            th = j * TAU / segs
            rr = r * (1.0 + lumps * _n(i * 3.1 + seed, j * 2.3))
            v.append((rr * math.sin(phi) * math.cos(th),
                      rr * math.sin(phi) * math.sin(th),
                      rr * math.cos(phi) * squash))
    v.append((0.0, 0.0, -r * squash))
    t = []
    for j in range(segs):
        t.append((0, 1 + j, 1 + (j + 1) % segs))
    for i in range(rings - 3):
        a, b = 1 + i * segs, 1 + (i + 1) * segs
        for j in range(segs):
            k = (j + 1) % segs
            t += [(a + j, b + j, b + k), (a + j, b + k, a + k)]
    last = 1 + (rings - 3) * segs
    end = len(v) - 1
    for j in range(segs):
        t.append((end, last + (j + 1) % segs, last + j))
    return v, t


def shard(r=1.0, h=2.0, sides=6, taper=0.12, lean=0.0, seed=0.0):
    """An angular rock splinter standing on z=0. Tris: sides * 3 - 2."""
    v = []
    for j in range(sides):
        a = j * TAU / sides
        rr = r * (1.0 + 0.3 * _n(j * 2.7 + seed))
        v.append((rr * math.cos(a), rr * math.sin(a), 0.0))
    for j in range(sides):
        a = j * TAU / sides
        rr = r * taper * (1.0 + 0.4 * _n(j * 1.3 + seed + 5.0))
        v.append((rr * math.cos(a) + lean, rr * math.sin(a), h))
    t = []
    for j in range(1, sides - 1):
        t.append((0, j + 1, j))
    for j in range(sides):
        k = (j + 1) % sides
        t += [(j, k, sides + k), (j, sides + k, sides + j)]
    for j in range(1, sides - 1):
        t.append((sides, sides + j, sides + j + 1))
    return v, t
