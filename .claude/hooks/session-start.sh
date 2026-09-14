#!/bin/bash
# SessionStart hook — make Godot available so GDScript can actually be verified.
#
# Without this, a session can write GDScript but cannot parse-check it, run the
# headless tests, or catch a broken .tscn. With it, every session can run:
#   "$GODOT" --headless --path <proj> --check-only --script <file>
#   "$GODOT" --headless --path spikes/01-terrain-perf --script tests/headless_check.gd
#
# It does NOT install Android export templates or the Android SDK — device runs
# stay on real hardware, which is the point.
set -euo pipefail

# Local machines almost certainly have their own Godot; don't fight it.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

GODOT_VERSION="4.7.2-stable"         # must match the version pinned in CLAUDE.md
GODOT_DIR="$HOME/.cache/sentinel-godot/$GODOT_VERSION"
GODOT_BIN="$GODOT_DIR/Godot_v${GODOT_VERSION}_linux.x86_64"

if [ ! -x "$GODOT_BIN" ] || ! "$GODOT_BIN" --headless --version >/dev/null 2>&1; then
  echo "Installing Godot $GODOT_VERSION (headless-capable) ..."
  mkdir -p "$GODOT_DIR"
  URL="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_linux.x86_64.zip"
  if curl -fsSL --retry 3 --retry-delay 2 --max-time 300 -o "$GODOT_DIR/godot.zip" "$URL"; then
    unzip -oq "$GODOT_DIR/godot.zip" -d "$GODOT_DIR"
    rm -f "$GODOT_DIR/godot.zip"
    chmod +x "$GODOT_BIN" 2>/dev/null || true
  else
    # A missing engine is a degraded session, not a broken one — the JS
    # prototype and the docs are still fully workable. Don't fail the session.
    echo "WARNING: could not download Godot; GDScript verification unavailable." >&2
    exit 0
  fi
fi

if ! "$GODOT_BIN" --headless --version >/dev/null 2>&1; then
  echo "WARNING: Godot downloaded but will not run; GDScript verification unavailable." >&2
  exit 0
fi

echo "Godot ready: $("$GODOT_BIN" --headless --version 2>/dev/null | tail -1)"

# Expose it to the rest of the session.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export GODOT=\"$GODOT_BIN\"" >> "$CLAUDE_ENV_FILE"
fi

# Prime the import caches so the very first --check-only resolves class_name
# globals. Without this, every script reports phantom "Could not find type"
# errors until something imports the project.
for proj in "$CLAUDE_PROJECT_DIR" "$CLAUDE_PROJECT_DIR/spikes/01-terrain-perf"; do
  if [ -f "$proj/project.godot" ]; then
    "$GODOT_BIN" --headless --path "$proj" --import >/dev/null 2>&1 || true
  fi
done

echo "Godot project caches primed."

# GUT, so the main project's unit tests can actually run. Best-effort: this
# host is not always reachable under an egress policy, and a missing test
# runner is a degraded session, not a broken one — tools/lint.sh reports the
# affected suites as skipped rather than passed.
GUT_VERSION="v9.3.0"
if [ ! -d "$CLAUDE_PROJECT_DIR/addons/gut" ]; then
  TMP="$(mktemp -d)"
  if curl -fsSL --retry 2 --max-time 120 -o "$TMP/gut.zip" \
       "https://github.com/bitwes/Gut/archive/refs/tags/${GUT_VERSION}.zip" 2>/dev/null \
     && unzip -oq "$TMP/gut.zip" -d "$TMP" 2>/dev/null; then
    SRC="$(find "$TMP" -maxdepth 3 -type d -name gut -path '*/addons/*' | head -1)"
    if [ -n "$SRC" ]; then
      mkdir -p "$CLAUDE_PROJECT_DIR/addons"
      cp -r "$SRC" "$CLAUDE_PROJECT_DIR/addons/gut"
      echo "GUT $GUT_VERSION installed."
    fi
  else
    echo "NOTE: GUT could not be fetched (egress policy or network); GUT suites will be skipped." >&2
  fi
  rm -rf "$TMP"
fi
