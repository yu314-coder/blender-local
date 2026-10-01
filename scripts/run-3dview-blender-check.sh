#!/bin/bash
# The 3D View's Python, run the way the iPad runs it: Blender in background
# mode, factory settings, no 3D View area.
#
# What it checks is what the Swift actually sends — the dump prints it — and
# for a transform, Blender's result against where the drag's preview put
# things: Blender's mode and edit selection reaching the interface, the
# viewport's selection reaching Blender before an operator, the view-axis
# rotate and local scale, a mesh operator in one evaluation from any mode, a
# tap mirroring only the selection, and a sculpt stroke written into the mesh.
#
# Then Set Origin and Apply both ways round: Blender runs what the menus send
# (through BpyBridge.run itself), writes what its mirror sent for a set of
# scenes and what its operators then did, and the same binary replays that
# through ObjectTransformState — so a greyed-out row is held to Blender.
#
# Skipped, not failed, when Blender is not installed.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
BUILD="${TMPDIR:-/tmp}/blenderlocal-3dview-blender"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/dump" \
  Sources/BlenderLocalBridge/*.swift \
  Sources/BlenderLocalUI/Viewport/ViewportCamera.swift \
  Sources/BlenderLocalUI/Viewport/ViewportOptions.swift \
  Sources/BlenderLocalUI/Viewport/TransformGizmo.swift \
  Sources/BlenderLocalUI/Viewport/TransformGizmoGeometry.swift \
  tests/gizmo/stub.swift \
  tests/3dview/blender/main.swift
"$BUILD/dump" > "$BUILD/calls.txt"
rm -f "$BUILD/object-transform.json"
status=0
"$BLENDER" -b --factory-startup --python-exit-code 1 \
  --python tests/3dview/blender/verify.py -- "$BUILD/calls.txt" "$BUILD/object-transform.json" \
  || status=1
"$BUILD/dump" "$BUILD/object-transform.json" || status=1
exit $status
