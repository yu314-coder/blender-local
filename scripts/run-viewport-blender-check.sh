#!/bin/bash
# What a viewport tap and a gizmo drag actually do to Blender's scene.
#
# The interface used to set its own selection and only *log* the equivalent
# Python. Blender's selection therefore never changed, and `transform.translate`
# — which acts on Blender's selection, not the app's — moved whatever had been
# selected last. The dragged object snapped back on release because the mirror
# pass put it where Blender still had it, and a different object moved instead.
#
# Neither half of that is visible without a real Blender: the simulator's shim
# *is* the display cache, so the two cannot disagree there.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
BUILD="${TMPDIR:-/tmp}/blenderlocal-viewport-blender"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/dump" \
  Sources/BlenderLocalBridge/*.swift \
  tests/viewport/blender/main.swift
"$BUILD/dump" > "$BUILD/calls.txt"
exec "$BLENDER" -b --factory-startup --python tests/viewport/blender/verify.py -- "$BUILD/calls.txt"
