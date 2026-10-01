#!/bin/bash
# Snapping a move to vertices, edges and faces: what the search under the
# pointer finds and leaves out, how a constrained move meets it, and that a
# drag commits exactly what it previewed. Pure simd over the mirror's meshes,
# so it runs on the Mac without a simulator or Metal. What Blender makes of
# the Python, on Blender's own meshes, is scripts/run-tools-blender-check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-snap-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" \
  Sources/BlenderLocalBridge/*.swift \
  Sources/BlenderLocalUI/Viewport/ViewportCamera.swift \
  Sources/BlenderLocalUI/Viewport/ViewportOptions.swift \
  Sources/BlenderLocalUI/Viewport/TransformGizmo.swift \
  Sources/BlenderLocalUI/Viewport/TransformGizmoGeometry.swift \
  tests/gizmo/stub.swift \
  tests/snap/main.swift
exec "$BUILD/run"
