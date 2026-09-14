#!/bin/bash
# Parse-check every GDScript in the repo.
#
# Two diagnostics are filtered, both artifacts of checking files in ISOLATION
# rather than real defects:
#
#   "Identifier not found: <Autoload>"  — autoloads are registered in
#       project.godot and exist at runtime, but --check-only on a single file
#       does not instantiate them. Filtered for names actually declared in
#       [autoload]; an unknown identifier still fails.
#
#   "Could not find base class GutTest" — GUT is not vendored (see README).
#       Those suites are skipped with a notice, not silently passed.
#
# Usage: tools/lint.sh            (uses $GODOT, or finds a godot on PATH)
set -uo pipefail
cd "$(dirname "$0")/.."

GODOT="${GODOT:-$(command -v godot || command -v godot4 || true)}"
if [ -z "$GODOT" ] || ! "$GODOT" --headless --version >/dev/null 2>&1; then
  echo "lint: no usable Godot binary (set \$GODOT or install one) — cannot check GDScript." >&2
  exit 2
fi

# Autoload names declared in the main project — safe to ignore when isolated.
AUTOLOADS=$(sed -n '/^\[autoload\]/,/^\[/p' project.godot 2>/dev/null \
  | grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' | tr -d '=' | paste -sd'|' -)
[ -z "$AUTOLOADS" ] && AUTOLOADS="__none__"

fail=0; checked=0; skipped=0

check() {   # check <project-dir> <script-path-relative-to-project>
  local proj="$1" rel="$2" label="$3"
  local out
  out=$("$GODOT" --headless --path "$proj" --check-only --script "$rel" 2>&1 \
        | grep -E "Parse Error|Compile Error" \
        | grep -vE "Identifier not found: ($AUTOLOADS)")
  if echo "$out" | grep -q 'Could not find base class "GutTest"'; then
    echo "  skip $label  (GUT not vendored — see README)"
    skipped=$((skipped+1)); return
  fi
  if [ -n "$out" ]; then
    echo "  FAIL $label"; echo "$out" | sed 's/^/       /'
    fail=$((fail+1))
  else
    echo "  ok   $label"
    checked=$((checked+1))
  fi
}

echo "lint: $("$GODOT" --headless --version 2>/dev/null | tail -1)"
echo "lint: ignoring isolated-check autoload refs: ${AUTOLOADS//|/, }"
echo

echo "main project"
for f in autoload/*.gd scripts/resources/*.gd scripts/systems/*.gd tests/unit/*.gd; do
  [ -e "$f" ] || continue
  check "." "$f" "$f"
done

for spike in spikes/*/; do
  [ -f "$spike/project.godot" ] || continue
  echo; echo "${spike%/}"
  for f in "$spike"scripts/*.gd "$spike"tests/*.gd; do
    [ -e "$f" ] || continue
    check "$spike" "${f#"$spike"}" "$f"
  done
done

echo
echo "lint: $checked ok, $skipped skipped, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
