#!/usr/bin/env bash
# Time each effect on its own, in the real renderer.
#
#   ./tools/effect_cost.sh
#
# Needs a rasteriser, and this machine has no GPU, so it uses lavapipe and
# Xvfb exactly as tools/screenshot.sh does. READ tools/effect_cost.gd before
# believing any number this prints: a software rasteriser ranks work correctly
# and prices it wrongly.
set -euo pipefail

RES="${1:-1280x600}"
GODOT="${GODOT:-$HOME/.cache/sentinel-godot/4.7.2-stable/Godot_v4.7.2-stable_linux.x86_64}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ICD=/usr/share/vulkan/icd.d/lvp_icd.json
[ -f "$ICD" ] || { echo "no software Vulkan device ($ICD)" >&2; exit 1; }
command -v xvfb-run >/dev/null || { echo "need xvfb" >&2; exit 1; }

export VK_ICD_FILENAMES="$ICD"
cd "$ROOT"

# --rendering-method mobile, like every other measurement in this project:
# Forward+ and Mobile are different shaders and pricing one tells you nothing
# about the other.
xvfb-run -a -s "-screen 0 ${RES}x24" "$GODOT" \
	--path . \
	--rendering-driver vulkan \
	--rendering-method mobile \
	--resolution "$RES" \
	--script tools/effect_cost.gd 2>&1 \
	| grep -vE "ALSA|alsa|snd_|audio driver|init_output_device" || true
