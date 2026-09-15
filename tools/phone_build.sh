#!/usr/bin/env bash
# Build, prove and zip the phone test project.
#
#   ./tools/phone_build.sh
#
# Four steps, and the middle two are the point. Assembling a folder is easy;
# what is worth automating is PROVING the folder opens and runs before it goes
# to a phone, because the round trip on a failure is a day.
set -euo pipefail

GODOT="${GODOT:-$HOME/.cache/sentinel-godot/4.7.2-stable/Godot_v4.7.2-stable_linux.x86_64}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build/phone/sentinel"
ZIP="$ROOT/build/phone/sentinel-phone-test.zip"

cd "$ROOT"

echo "== assemble"
"$GODOT" --headless --path . --script tools/export_phone_build.gd

echo
echo "== import it as its own project"
"$GODOT" --headless --path "$OUT" --import >/tmp/phone_import.log 2>&1
if grep -qiE '^(ERROR|SCRIPT ERROR)' /tmp/phone_import.log; then
	echo "  FAIL — import errors:"
	grep -iE '^(ERROR|SCRIPT ERROR)' /tmp/phone_import.log | head
	exit 1
fi
echo "  ok   imported clean"

echo
echo "== boot it"
# 240 frames of the real main scene: terrain build, scatter, fog, the lot.
# Headless has no renderer, but every GDScript path still runs, and a build
# that throws on frame one is not something to find out about on the phone.
"$GODOT" --headless --path "$OUT" --quit-after 240 >/tmp/phone_boot.log 2>&1
if grep -qiE '^(ERROR|SCRIPT ERROR)' /tmp/phone_boot.log; then
	echo "  FAIL — the build does not run:"
	grep -iE '^(ERROR|SCRIPT ERROR)' /tmp/phone_boot.log | head
	exit 1
fi
echo "  ok   240 frames, no errors"

echo
echo "== zip"
# The .godot import cache is NOT shipped: it is several megabytes, it is
# desktop-specific, and the phone regenerates it on first open anyway.
rm -f "$ZIP"
( cd "$ROOT/build/phone" && zip -qr "$ZIP" sentinel -x 'sentinel/.godot/*' )
echo "  ok   $ZIP  ($(du -h "$ZIP" | cut -f1))"
