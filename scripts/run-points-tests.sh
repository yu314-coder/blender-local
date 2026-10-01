#!/bin/bash
# Edit Mode on curves and lattices, the Swift half: the control points the
# mirror hands over, a tap, a box, the gizmo's points drag, the Data tab's
# settings and the Python each control sends. Blender's half is
# run-points-blender-check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-points-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" \
  Sources/BlenderLocalBridge/*.swift \
  Sources/BlenderLocalUI/Viewport/ViewportCamera.swift \
  Sources/BlenderLocalUI/Viewport/ViewportOptions.swift \
  Sources/BlenderLocalUI/Viewport/TransformGizmo.swift \
  Sources/BlenderLocalUI/Viewport/TransformGizmoGeometry.swift \
  tests/gizmo/stub.swift \
  tests/points/main.swift
exec "$BUILD/run"
