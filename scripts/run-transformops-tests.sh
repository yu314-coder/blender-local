#!/bin/bash
# Typed values in Edit Mode, transform orientations, the gizmo's redo panel
# and typed Dimensions on the Swift side: Blender's orientation names and the
# report the mirror reads, the gizmo drawn on the orientation's axes, a drag's
# commit as the redo panel's operator (its rows by Blender's names, the rows
# Blender hides, the matrix and the values the preview multiplies), the Item
# tab's state and calls, and what reaches Blender in which order. Pure simd
# and strings. What Blender makes of it is
# scripts/run-transformops-blender-check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-transformops-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" \
  Sources/BlenderLocalBridge/*.swift \
  Sources/BlenderLocalUI/Viewport/ViewportCamera.swift \
  Sources/BlenderLocalUI/Viewport/ViewportOptions.swift \
  Sources/BlenderLocalUI/Viewport/TransformGizmo.swift \
  Sources/BlenderLocalUI/Viewport/TransformGizmoGeometry.swift \
  tests/gizmo/stub.swift \
  tests/transformops/main.swift
exec "$BUILD/run"
