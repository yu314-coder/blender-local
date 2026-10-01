#!/bin/bash
# The modifier rows, run the way the iPad runs them: Blender in background
# mode, factory settings, no 3D View area.
#
# Both halves of the round trip. Blender runs exactly the Python each row
# sends, and says whether it took, where the value landed and what the
# evaluated mesh did; then the Swift parses the record Blender's own
# `_modifier_record` built from that scene, as the panel would.
#
# Skipped, not failed, when Blender is not installed.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
BUILD="${TMPDIR:-/tmp}/blenderlocal-modifier-blender"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/dump" Sources/BlenderLocalBridge/*.swift tests/modifiers/blender/main.swift
"$BUILD/dump" > "$BUILD/calls.txt"
"$BLENDER" -b --factory-startup --python-exit-code 1 \
  --python tests/modifiers/blender/verify.py -- "$BUILD/calls.txt" "$BUILD/records.txt" "$BUILD/dump"
exec "$BUILD/dump" "$BUILD/records.txt"
