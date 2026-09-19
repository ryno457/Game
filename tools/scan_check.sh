#!/usr/bin/env bash
# Photograph the drone's scan and measure it against a floor measured in the
# same run. See tools/scan_check.gd for why counting is the point.
#
#   ./tools/scan_check.sh [name] [WxH]
set -euo pipefail

TAG="${1:-scan}"
RES="${2:-1600x900}"
GODOT="${GODOT:-$HOME/.cache/sentinel-godot/4.7.2-stable/Godot_v4.7.2-stable_linux.x86_64}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ICD=/usr/share/vulkan/icd.d/lvp_icd.json
[ -f "$ICD" ] || { echo "no software Vulkan device found ($ICD)" >&2; exit 1; }
command -v xvfb-run >/dev/null || { echo "need xvfb" >&2; exit 1; }

export VK_ICD_FILENAMES="$ICD"
cd "$ROOT"

# mobile, not Forward+: the material bug this check exists for only bites on
# the Mobile renderer, so a Forward+ run would pass while the phone drew
# nothing.
set +e
xvfb-run -a -s "-screen 0 ${RES}x24" "$GODOT" \
	--path . \
	--rendering-driver vulkan \
	--rendering-method mobile \
	--resolution "$RES" \
	--script tools/scan_check.gd \
	-- "$TAG" "${3:-}" 2>&1 | grep -vE "ALSA|alsa|snd_|audio driver|init_output_device"
rc=${PIPESTATUS[0]}
set -e
echo "  -> build/shots/${TAG}_on.png, build/shots/${TAG}_off.png"
exit "$rc"
