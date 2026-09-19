#!/usr/bin/env bash
# Shots to kill, printed and asserted. See tools/balance_check.gd.
set -euo pipefail
GODOT="${GODOT:-$HOME/.cache/sentinel-godot/4.7.2-stable/Godot_v4.7.2-stable_linux.x86_64}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
set +e
"$GODOT" --headless --path . --script tools/balance_check.gd 2>&1 \
	| grep -vE "ALSA|alsa|snd_|audio driver|init_output_device"
rc=${PIPESTATUS[0]}
set -e
exit "$rc"
