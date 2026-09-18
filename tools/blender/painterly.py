"""Run a baked texture through Blender's Kuwahara filter.

    ~/.cache/blender-venv/bin/python tools/blender/painterly.py \
        textures/ground_vines_c.png build/painterly/out.png \
        --size 6 --type anisotropic --sharpness 1 --eccentricity 1

WHY THIS IS A BAKE-TIME TOOL AND NOT A SHADER.
The Kuwahara filter is what gives a rendered frame an oil-paint read: it
replaces each pixel with the mean of whichever neighbourhood sector has the
lowest variance, so flat areas smear into patches while edges stay put. It is
also, for that reason, expensive — the classic variant at radius r costs four
sectors of (r+1)^2 taps, 64 taps a pixel at r=3, and the anisotropic variant
adds a structure-tensor pass on top. That is not a per-frame cost a phone under
thermal throttle can carry (CLAUDE.md risk 4), and this project does not need
it to be: the terrain is a FIXED shape with a real unwrap and a whole-map baked
albedo, so the filter can run ONCE, here, and ship as pixels.

Blender has the node built in since 4.0 — `CompositorNodeKuwahara`. No add-on
is involved, and nothing is downloaded.

IT CHECKS ITSELF. At size 0 the filter is the identity, and this asserts that
the round trip through the compositor returns the input unchanged. A colour
pipeline that silently applies a view transform would fail that and pass
everything else, and the failure would look like "the filter darkened it".
"""
import os
import sys

import bpy
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _bl import script_args                                      # noqa: E402

TYPES = {"anisotropic": "Anisotropic", "classic": "Classic"}


def _args(argv):
    out = {"size": 6.0, "type": "anisotropic", "uniformity": 4,
           "sharpness": 1.0, "eccentricity": 1.0, "high_precision": False}
    rest = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a.startswith("--"):
            key = a[2:].replace("-", "_")
            if key == "high_precision":
                out[key] = True
                i += 1
                continue
            val = argv[i + 1]
            out[key] = int(val) if key == "uniformity" else \
                (val if key == "type" else float(val))
            i += 2
        else:
            rest.append(a)
            i += 1
    return rest, out


def pixels(img):
    buf = np.empty(len(img.pixels), dtype=np.float32)
    img.pixels.foreach_get(buf)
    return buf.reshape(img.size[1], img.size[0], img.channels)


def filter_image(src_path, dst_path, opts):
    src = bpy.data.images.load(os.path.abspath(src_path))
    # The bake is an sRGB colour texture and has to come back out as one. Left
    # on Filmic/AgX the whole point would be lost in a tone curve.
    src.colorspace_settings.name = "sRGB"
    w, h = src.size
    before = pixels(src).copy()

    sc = bpy.context.scene
    # The 3D scene is irrelevant — the compositor output never touches Render
    # Layers — but a render still runs one, so it is made free rather than
    # rendering a default cube at 2048 px for nothing.
    sc.render.engine = "BLENDER_WORKBENCH"
    sc.render.use_compositing = True
    sc.render.resolution_x, sc.render.resolution_y = w, h
    sc.render.resolution_percentage = 100
    sc.render.film_transparent = False
    sc.view_settings.view_transform = "Standard"
    sc.view_settings.look = "None"
    sc.render.image_settings.file_format = "PNG"
    sc.render.image_settings.color_mode = "RGB"
    sc.render.image_settings.color_depth = "8"

    # Blender 5.0 keeps the compositor as a node group on the scene; 4.x used
    # scene.node_tree. Both are handled so this runs under either.
    ng = bpy.data.node_groups.new("painterly", "CompositorNodeTree")
    if hasattr(sc, "compositing_node_group"):
        sc.compositing_node_group = ng
    else:
        sc.use_nodes = True
        ng = sc.node_tree
        ng.nodes.clear()

    n_img = ng.nodes.new("CompositorNodeImage")
    n_img.image = src
    n_k = ng.nodes.new("CompositorNodeKuwahara")
    # A File Output node, not a Composite node. Blender 5.0 removed
    # CompositorNodeComposite — the scene's compositing tree now returns
    # through a group output — and File Output writes the filtered image
    # straight to disk without going near the render result.
    # THE GROUP OUTPUT IS THE COMPOSITE OUTPUT in Blender 5.0. There is no
    # CompositorNodeComposite any more — the scene's compositing tree is an
    # ordinary node group and whatever reaches its output socket becomes the
    # render result. A Viewer node looks like the obvious alternative and is
    # not: it stays empty in a background render, which reads exactly like
    # "the filter did nothing".
    if hasattr(ng, "interface"):
        ng.interface.new_socket("Image", in_out="OUTPUT",
                                socket_type="NodeSocketColor")
        n_out = ng.nodes.new("NodeGroupOutput")
        ng.links.new(n_img.outputs["Image"], n_k.inputs["Image"])
        ng.links.new(n_k.outputs["Image"], n_out.inputs[0])
    else:
        n_out = ng.nodes.new("CompositorNodeComposite")
        ng.links.new(n_img.outputs["Image"], n_k.inputs["Image"])
        ng.links.new(n_k.outputs["Image"], n_out.inputs["Image"])

    def put(name, value):
        if name in n_k.inputs:
            n_k.inputs[name].default_value = value
    put("Size", opts["size"])
    put("Type", TYPES[opts["type"]])
    put("Uniformity", opts["uniformity"])
    put("Sharpness", opts["sharpness"])
    put("Eccentricity", opts["eccentricity"])
    put("High Precision", opts["high_precision"])
    # 4.x carried these as node properties rather than sockets.
    for prop, val in (("variation", TYPES[opts["type"]].upper()),
                      ("size", int(opts["size"])),
                      ("uniformity", opts["uniformity"]),
                      ("sharpness", opts["sharpness"]),
                      ("eccentricity", opts["eccentricity"])):
        if hasattr(n_k, prop):
            setattr(n_k, prop, val)

    os.makedirs(os.path.dirname(os.path.abspath(dst_path)), exist_ok=True)
    sc.render.filepath = os.path.abspath(dst_path)
    sc.frame_set(1)
    bpy.ops.render.render(write_still=True)
    assert os.path.exists(dst_path), "the compositor wrote nothing"

    out = bpy.data.images.load(os.path.abspath(dst_path))
    after = pixels(out).copy()
    bpy.data.images.remove(out)
    bpy.data.images.remove(src)
    bpy.data.node_groups.remove(ng)
    return before, after


def report(before, after, opts):
    b = before[..., :3]
    a = after[..., :3]
    # Local contrast: mean absolute difference between horizontal neighbours.
    # This is the number the filter exists to move — flat areas lose it, edges
    # keep it — so it says more than a mean or a histogram would.
    det = lambda x: float(np.abs(x[:, 1:] - x[:, :-1]).mean())
    d_b, d_a = det(b), det(a)
    print("PY: size %.1f %s  sharp %.2f  ecc %.2f"
          % (opts["size"], opts["type"], opts["sharpness"],
             opts["eccentricity"]))
    print("PY:   mean luma   %.4f -> %.4f" % (b.mean(), a.mean()))
    print("PY:   local detail %.5f -> %.5f  (%.0f%% kept)"
          % (d_b, d_a, 100.0 * d_a / max(1e-9, d_b)))
    print("PY:   worst pixel  %.4f" % float(np.abs(a - b).max()))
    return d_b, d_a


def main():
    argv = script_args()
    rest, opts = _args(argv)
    if len(rest) < 2:
        print(__doc__)
        return
    src, dst = rest[0], rest[1]

    # THE IDENTITY CHECK, first and always. Size 0 must come back unchanged.
    ident_b, ident_a = filter_image(src, "/tmp/painterly_identity.png",
                                    dict(opts, size=0.0))
    worst = float(np.abs(ident_a[..., :3] - ident_b[..., :3]).max())
    print("PY: identity round trip, worst channel off by %.4f" % worst)
    assert worst < 0.02, (
        "size 0 is the identity filter and it changed the image by %.3f — the "
        "colour pipeline is wrong, not the filter" % worst)

    before, after = filter_image(src, dst, opts)
    report(before, after, opts)
    print("PY: wrote %s" % dst)


main()
