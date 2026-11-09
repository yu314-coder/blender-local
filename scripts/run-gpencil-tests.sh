#!/bin/bash
# Grease Pencil's Swift half (tests/gpencil/main.swift): the mirror's record
# read and refused when malformed, the ribbons and fills the viewport draws
# and their order, onion skins, the stroke projected onto Blender's drawing
# plane with Blender's radius and opacity, thinned, smoothed and simplified,
# picking, and what 20,000 points cost. What Blender makes of the strokes
# written this way is scripts/run-gpencil-blender-check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-gpencil-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" \
  Sources/BlenderLocalBridge/*.swift \
  Sources/BlenderLocalUI/Viewport/ViewportCamera.swift \
  tests/gpencil/main.swift
exec "$BUILD/run"
