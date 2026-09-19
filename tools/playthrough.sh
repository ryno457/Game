#!/usr/bin/env bash
# Drive the game on the software rasteriser and film it.
#   tools/playthrough.sh [seconds] [WxH]
set -euo pipefail
GODOT="${GODOT:-$HOME/.cache/sentinel-godot/4.7.2-stable/Godot_v4.7.2-stable_linux.x86_64}"
SECS="${1:-24}"
RES="${2:-1280x720}"
exec xvfb-run -a -s "-screen 0 ${RES}x24" "$GODOT" --path . \
  --resolution "$RES" --script tools/playthrough.gd -- "$SECS"
