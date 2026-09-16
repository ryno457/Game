"""Measure a render against the value structure of the reference art.

    ~/.cache/blender-venv/bin/python tools/look_check.py build/shots/godot_view.png

CLAUDE.md says any system with a numeric threshold gets a test, and "does this
look like the reference" turned out to BE a numeric threshold — a very sharp one.

Measured across all three references, the agreement is remarkable:

                       ref 01   ref 03   ref 04
    median luma         0.233    0.233    0.232
    in the DARK third     78%      71%      67%
    in the LIGHT third     0%       3%       5%
    median saturation    0.54     0.41     0.47

Three paintings by different hands, made at different crops, landing on the
same median luminance to three decimal places. That is not a coincidence — it
is what "a dark scene with small bright accents" measures as, and it is the
single most objective thing that can be said about the target look.

The build at the time this was written measured 53% dark / 30% LIGHT and a
median saturation of 0.29: six times too much bright area and half the colour.
That is why it reads as a flat pastel map rather than a bioluminescent cavern,
and no amount of hue tweaking fixes it, because the defect is in the value
distribution and not in the palette.

This does NOT check composition, detail density, or whether the roots read as
roots. It checks the one thing that can be checked without an eye, which is
worth exactly as much as that and no more.
"""
import os
import sys

import numpy as np
from PIL import Image

REFS = [
    # (path, crop as fractions l,t,r,b, why the crop)
    ("docs/reference/01-vtt-cavern-map.jpg", (0.0, 0.14, 1.0, 0.88),
     "phone screenshot: chrome top and bottom"),
    ("docs/reference/03-detail-painting.png", None, ""),
    ("docs/reference/04-moonlit-ravine.png", None, ""),
]

# The game's own frame is mostly HUD at the edges. Measuring the whole frame
# would score the UI's dark panels as if they were terrain, which flatters the
# result for the wrong reason.
GAME_CROP = (0.18, 0.08, 0.68, 0.95)

# How far off target is still acceptable. Wider than the references' own spread
# because a game frame is not a painting: it carries a module, units and a grid
# the references do not have.
TOL_LUMA = 0.06
MAX_LIGHT = 0.12      # references run 0-5%; 12% leaves room for glows and UI bleed
MIN_DARK = 0.55       # references run 67-78%
TOL_SAT = 0.12


def measure(path, crop=None):
    a = np.asarray(Image.open(path).convert("RGB"), np.float32) / 255.0
    if crop:
        h, w, _ = a.shape
        a = a[int(h * crop[1]):int(h * crop[3]), int(w * crop[0]):int(w * crop[2])]
    lum = a @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    mx, mn = a.max(-1), a.min(-1)
    sat = np.where(mx > 0, (mx - mn) / np.maximum(mx, 1e-6), 0.0)
    dark = float(np.count_nonzero(lum < 1 / 3) / lum.size)
    light = float(np.count_nonzero(lum >= 2 / 3) / lum.size)
    q1, q3 = np.percentile(lum, 25), np.percentile(lum, 75)
    return dict(
        luma=float(np.median(lum)), dark=dark, light=light,
        sat=float(np.median(sat)),
        # The painter's rule: an occlusion shadow is darker AND more saturated.
        # Every reference shows it; a renderer that only multiplies brightness
        # cannot, so it is worth reporting even though it is not scored.
        sat_dark=float(np.median(sat[lum < q1])),
        sat_light=float(np.median(sat[lum > q3])),
    )


def main():
    target_src = []
    for path, crop, _ in REFS:
        if os.path.exists(path):
            target_src.append(measure(path, crop))
    if not target_src:
        raise SystemExit("no reference images in docs/reference — cannot judge anything")

    def avg(k):
        return sum(t[k] for t in target_src) / len(target_src)

    want = {k: avg(k) for k in ("luma", "dark", "light", "sat")}
    print("target, averaged over %d reference images" % len(target_src))
    print("   median luma %.3f   dark %.0f%%   light %.0f%%   saturation %.2f\n"
          % (want["luma"], 100 * want["dark"], 100 * want["light"], want["sat"]))

    shots = sys.argv[1:] or ["build/shots/godot_view.png"]
    failed = 0
    for shot in shots:
        if not os.path.exists(shot):
            print("  MISSING  %s" % shot)
            failed += 1
            continue
        g = measure(shot, GAME_CROP)
        print("== %s" % shot)
        checks = [
            ("overall value is right", abs(g["luma"] - want["luma"]) < TOL_LUMA,
             "median luma %.3f against %.3f" % (g["luma"], want["luma"])),
            ("it is not washed out", g["light"] < MAX_LIGHT,
             "%.0f%% of the frame is in the light third, limit %.0f%%"
             % (100 * g["light"], 100 * MAX_LIGHT)),
            ("it is mostly dark, as the references are", g["dark"] > MIN_DARK,
             "%.0f%% dark, want over %.0f%%" % (100 * g["dark"], 100 * MIN_DARK)),
            ("the colour is as saturated as the paint", abs(g["sat"] - want["sat"]) < TOL_SAT,
             "median saturation %.2f against %.2f" % (g["sat"], want["sat"])),
        ]
        for name, ok, detail in checks:
            if not ok:
                failed += 1
            print("  %s  %-40s %s" % ("PASS" if ok else "FAIL", name, detail))
        print("       (shadows are %s saturated than highlights: %.2f vs %.2f)"
              % ("MORE" if g["sat_dark"] > g["sat_light"] else "LESS",
                 g["sat_dark"], g["sat_light"]))
        print()

    print("ALL CHECKS PASSED" if failed == 0 else "%d CHECK(S) FAILED" % failed)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
