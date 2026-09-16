#!/usr/bin/env bash
# Save a real frame out of Godot, with every effect on.
#
#   ./tools/screenshot.sh [name.png] [settle_frames] [WxH]
#
# Every other picture of this game is drawn by a DIFFERENT renderer — Blender's
# Cycles in tools/blender, or a numpy port of the shader's own arithmetic in
# tools/paint_preview.py. Both are useful. Both have lied at least once, and the
# worst of those lies was invisible until this script existed: neither of them
# models the FOG OF WAR, so neither could show that 91% of the map was rendering
# as a sheet of pale haze.
#
# This is the actual engine. Real terrain shader, real tone ramp, real AO and
# curvature, real ink pass, real cloud deck, real HUD, real tonemapper, and the
# Forward MOBILE renderer that actually ships rather than Forward+.
#
# It needs a rasteriser, and this machine has no GPU, so it uses:
#   - lavapipe, Mesa's software Vulkan device (package mesa-vulkan-drivers)
#   - Xvfb, a virtual X display
# Slow — about a minute for one 2400x1080 frame — which is fine for a still.
set -euo pipefail

OUT="${1:-godot_view.png}"
FRAMES="${2:-120}"
RES="${3:-2400x1080}"
# Pass "reveal" as the 4th arg to open the fog. Needed to compare the art
# against a painting, which has no fog; leave it off for a shot of what the
# player actually sees on frame one.
REVEAL="${4:-}"
GODOT="${GODOT:-$HOME/.cache/sentinel-godot/4.7.2-stable/Godot_v4.7.2-stable_linux.x86_64}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ICD=/usr/share/vulkan/icd.d/lvp_icd.json
if [ ! -f "$ICD" ]; then
	echo "no software Vulkan device found ($ICD)." >&2
	echo "  sudo apt-get install -y mesa-vulkan-drivers xvfb" >&2
	echo "On a machine with a real GPU, drop VK_ICD_FILENAMES and xvfb-run." >&2
	exit 1
fi
command -v xvfb-run >/dev/null || { echo "need xvfb (apt install xvfb)" >&2; exit 1; }

export VK_ICD_FILENAMES="$ICD"
cd "$ROOT"

# --rendering-method mobile is NOT optional. Without it Godot picks Forward+ on
# a desktop build, and the two renderers are different shaders: the whole reason
# terrain_lit.gdshader is written the way it is, is the Mobile feature set.
xvfb-run -a -s "-screen 0 ${RES}x24" "$GODOT" \
	--path . \
	--rendering-driver vulkan \
	--rendering-method mobile \
	--resolution "$RES" \
	--script tools/screenshot.gd \
	-- "$OUT" "$FRAMES" "$REVEAL" 2>&1 | grep -vE "ALSA|alsa|snd_|audio driver|init_output_device" || true

echo "  -> build/shots/$OUT"
