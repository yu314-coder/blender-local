#!/bin/bash
# The UV Editor, run the way the iPad runs it: Blender in background mode,
# factory settings, no UV Editor area in the context.
#
# Every row of the UV menu is run exactly as the Swift sends it, through the
# app's own _blenderkit_uv, from object mode (the whole mesh, Edit Mode's
# selection put back) and from Edit Mode (the selected faces, as in Blender).
# Then the app's own _blenderkit_sync.py pushes scenes with UV maps and seams,
# which the Swift the device runs builds and merges: Blender's UV for every
# drawn corner, its seams, its polygon edges without the diagonals, and the
# unchanged-mesh fast path still taken when nothing changed.
#
# Skipped, not failed, when Blender is not installed.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
BUILD="${TMPDIR:-/tmp}/blenderlocal-uv-blender"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/dump" Sources/BlenderLocalBridge/*.swift tests/uv/blender/main.swift
"$BUILD/dump" > "$BUILD/calls.txt"
"$BLENDER" -b --factory-startup --python-exit-code 1 \
  --python tests/uv/blender/verify.py -- "$BUILD/calls.txt" "$BUILD/passes.json"
exec "$BUILD/dump" "$BUILD/passes.json"
