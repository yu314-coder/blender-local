#!/bin/bash
# The mirror, run the way the iPad runs it: Blender in background mode, factory
# settings, the app's own _blenderkit_sync.py pushing the scene, and the Swift
# the device runs building, merging and showing what it pushed.
#
# The scene is the one the mirror used to drop half of: the Add menu's wire
# circle, an unfilled curve, edge-only and vertex-only meshes, empty ones, a
# mesh past the vertex limit — and a modifier added to an object already on
# screen, the other thing that never reached it.
#
# Skipped, not failed, when Blender is not installed.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
BUILD="${TMPDIR:-/tmp}/blenderlocal-mirror-blender"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/dump" Sources/BlenderLocalBridge/*.swift tests/mirror/blender/main.swift
"$BUILD/dump" > "$BUILD/calls.txt"
"$BLENDER" -b --factory-startup --python-exit-code 1 \
  --python tests/mirror/blender/verify.py -- "$BUILD/calls.txt" "$BUILD/passes.json"
exec "$BUILD/dump" "$BUILD/passes.json"
