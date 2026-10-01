#!/bin/bash
# Snapping, the pivot point and proportional editing on the Swift side: the
# mirror's packing, the Python each control sends, and where the gizmo pivots.
# Pure simd and strings, so it runs on the Mac without a simulator or Metal.
# What Blender makes of that Python is scripts/run-tools-blender-check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-tools-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" \
  Sources/BlenderLocalBridge/*.swift \
  Sources/BlenderLocalUI/Viewport/ViewportCamera.swift \
  Sources/BlenderLocalUI/Viewport/ViewportOptions.swift \
  Sources/BlenderLocalUI/Viewport/TransformGizmo.swift \
  Sources/BlenderLocalUI/Viewport/TransformGizmoGeometry.swift \
  tests/gizmo/stub.swift \
  tests/tools/main.swift
exec "$BUILD/run"
