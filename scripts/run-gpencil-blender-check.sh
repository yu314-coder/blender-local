#!/bin/bash
# Grease Pencil run the way the iPad runs it: Blender in background mode,
# factory settings, the strings the Swift sends (printed by
# tests/gpencil/blender/main.swift) through the modules the app ships.
#
# Add ▸ Grease Pencil, Draw Mode, strokes made by the app landing where
# Blender's own aimed 3D View draws them, Auto Keying and Additive Drawing,
# onion skins and the timeline's keys, the mirror's record and its cost at
# 20,000 points, undo, the Eraser, the Layers panel, materials, the brush and
# every name shown. See verify.py.
#
# Blender gets a home of its own under the work directory. Skipped, not
# failed, when Blender is not installed.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/blenderlocal-gpencil-blender.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home/res" "$WORK/tmp"
swiftc -Onone -o "$WORK/dump" Sources/BlenderLocalBridge/*.swift \
  Sources/BlenderLocalUI/Viewport/ViewportCamera.swift tests/gpencil/blender/main.swift
"$WORK/dump" > "$WORK/calls.txt"
ROOT="$(pwd)"
cd "$WORK"
HOME="$WORK/home" BLENDER_USER_RESOURCES="$WORK/home/res" TMPDIR="$WORK/tmp" "$BLENDER" -b --factory-startup \
  --python-exit-code 1 --python "$ROOT/tests/gpencil/blender/verify.py" -- "$WORK/calls.txt" 2>&1 \
  | grep -vE '^(Blender [0-9]|Read prefs|$)'
exit "${PIPESTATUS[0]}"
