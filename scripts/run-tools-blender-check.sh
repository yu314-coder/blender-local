#!/bin/bash
# Snapping, the pivot point and proportional editing, run the way the iPad runs
# them: Blender in background mode, factory settings, no 3D View area.
#
# What it checks is what the Swift actually sends — the dump prints it — and,
# for every drag, Blender's result against where the drag's preview put
# things: snapped, pivoted and proportionally weighted, in object mode and on
# Blender's own meshes in edit mode. It is also the only check that can hold
# `_blenderkit_tools.snap` against real Blender, because the operators it
# stands in for cannot poll here.
#
# Three steps: Blender writes out its edit-mode meshes, the Swift previews its
# drags on exactly those and prints the Python and the result, and Blender
# runs the Python and compares.
#
# Skipped, not failed, when Blender is not installed.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
BUILD="${TMPDIR:-/tmp}/blenderlocal-tools-blender"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/dump" \
  Sources/BlenderLocalBridge/*.swift \
  Sources/BlenderLocalUI/Viewport/ViewportCamera.swift \
  Sources/BlenderLocalUI/Viewport/ViewportOptions.swift \
  Sources/BlenderLocalUI/Viewport/TransformGizmo.swift \
  Sources/BlenderLocalUI/Viewport/TransformGizmoGeometry.swift \
  tests/gizmo/stub.swift \
  tests/tools/blender/main.swift
"$BLENDER" -b --factory-startup --python tests/tools/blender/meshes.py -- "$BUILD/meshes.json" \
  | grep -E "wrote|Error|Traceback" || true
"$BUILD/dump" "$BUILD/meshes.json" > "$BUILD/calls.txt"
exec "$BLENDER" -b --factory-startup --python tests/tools/blender/verify.py -- "$BUILD/calls.txt"
