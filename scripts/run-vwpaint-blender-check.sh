#!/bin/bash
# Weight Paint and Vertex Paint with Blender's own brushes, run the way the
# app runs them: Blender in background mode, factory settings, the strings the
# Swift sends (printed by tests/vwpaint/blender/main.swift) through the modules
# the app ships (_blenderkit_vwpaint, _blenderkit_sculpt's view, the undo
# history).
#
# Into and out of both modes and the names Blender's history gives them; the
# refusals; a stroke streamed in chunks against the same dabs as one of
# Blender's strokes, for every Essentials brush of both modes, with Undo and
# Redo; the brush settings read back; what the viewport is handed; a stroke
# after a file load has freed Blender's undo stack. See verify.py.
#
# Blender gets a home of its own under the work directory, so nothing it does
# reaches this Mac's Blender settings. Skipped, not failed, when Blender is not
# installed.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/blenderlocal-vwpaint-blender.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Documents" "$WORK/home/res"
swiftc -O -o "$WORK/dump" Sources/BlenderLocalBridge/*.swift \
  Sources/BlenderLocalUI/Viewport/ViewportCamera.swift tests/vwpaint/blender/main.swift
"$WORK/dump" > "$WORK/calls.txt"
echo "  $(grep -c '^###' "$WORK/calls.txt") strings from the Swift, put through Blender $("$BLENDER" --version | head -1 | cut -d' ' -f2)"
HOME="$WORK/home" BLENDER_USER_RESOURCES="$WORK/home/res" "$BLENDER" -b --factory-startup \
  --python-exit-code 1 --python tests/vwpaint/blender/verify.py -- "$WORK/calls.txt" "$WORK" 2>&1 \
  | grep -vE '^(Blender [0-9]|Read prefs|$|Info: Saved copy|Warning: Active group is locked)'
exit "${PIPESTATUS[0]}"
