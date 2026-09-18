#!/usr/bin/env python3
"""Fold the baked map into the browser editor page.

    tools/export_map_web.gd      # bakes build/web/{map.png,albedo.jpg,map.json}
    python3 tools/inline_map_web.py

tools/web_map_editor.html is deliberately ONE self-contained file: it gets
opened off a phone's downloads folder, or pasted into a chat artifact, and
neither of those can fetch a sibling file. So the three baked assets live
inside it as literals, and this rewrites those three literals in place.

They were pasted by hand the first time, which worked exactly once. A re-bake
that has to be transcribed is a re-bake that quietly does not happen, and then
the page is showing a map the game no longer has.
"""

import base64
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PAGE = ROOT / "tools/web_map_editor.html"
WEB = ROOT / "build/web"

# name in the page -> (file, mime).  None mime means "paste it raw".
SLOTS = {
    "MAP_PNG": (WEB / "map.png", "image/png"),
    "ALBEDO_JPG": (WEB / "albedo.jpg", "image/jpeg"),
    "M": (WEB / "map.json", None),
}


def main() -> int:
    if not PAGE.exists():
        print("no %s" % PAGE)
        return 1
    text = PAGE.read_text()
    missing = [str(f) for f, _ in SLOTS.values() if not f.exists()]
    if missing:
        print("bake first — missing:\n  " + "\n  ".join(missing))
        return 1

    for name, (path, mime) in SLOTS.items():
        if mime is None:
            # Reparsed rather than pasted through, so a truncated or
            # half-written bake fails HERE instead of in a browser console on
            # somebody's phone.
            value = json.dumps(json.loads(path.read_text()),
                               separators=(",", ":"), sort_keys=True)
        else:
            value = '"data:%s;base64,%s"' % (
                mime, base64.b64encode(path.read_bytes()).decode())
        pattern = re.compile(r"^const %s = .*?;$" % re.escape(name), re.M)
        found = len(pattern.findall(text))
        if found != 1:
            print("expected one `const %s = ...;` line, found %d" % (name, found))
            return 1
        text = pattern.sub(
            lambda _m, v=value, n=name: "const %s = %s;" % (n, v), text, count=1)
        print("  %-11s %8.0f kB  from %s"
              % (name, len(value) / 1024.0, path.relative_to(ROOT)))

    PAGE.write_text(text)
    print("\n  %s  %.0f kB" % (PAGE.relative_to(ROOT),
                               len(text) / 1024.0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
