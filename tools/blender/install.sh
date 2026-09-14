#!/bin/bash
# Install a current Blender as the `bpy` Python module.
#
# Why not a normal Blender install: download.blender.org is blocked by this
# environment's egress policy, and Ubuntu's apt build is 4.0 and ships without
# OpenImageDenoise. PyPI is reachable, and `bpy` is the full engine minus the
# GUI — which is all a headless pipeline needs.
#
# Deliberately NOT run from the SessionStart hook: this is a ~300 MB download
# and most sessions never touch Blender, so it stays on demand and session
# start stays fast.
#
#   tools/blender/install.sh          then use ~/.cache/blender-venv/bin/python
set -euo pipefail

VENV="${BLENDER_VENV:-$HOME/.cache/blender-venv}"

if [ -x "$VENV/bin/python" ] && "$VENV/bin/python" -c "import bpy" 2>/dev/null; then
  echo "bpy already installed: $("$VENV/bin/python" -c 'import bpy;print(bpy.app.version_string)')"
  echo "$VENV/bin/python"
  exit 0
fi

echo "Creating venv at $VENV ..."
python3 -m venv "$VENV"
"$VENV/bin/pip" install -q --upgrade pip
echo "Installing bpy (this is a large download) ..."
"$VENV/bin/pip" install -q bpy

"$VENV/bin/python" - <<'PY'
import bpy, numpy
print("bpy", bpy.app.version_string, "| numpy", numpy.__version__)
bpy.ops.wm.read_factory_settings(use_empty=True)
sc = bpy.context.scene
sc.render.engine = 'CYCLES'
print("denoiser:", getattr(sc.cycles, "denoiser", "n/a"))
PY
echo "$VENV/bin/python"
