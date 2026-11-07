#!/bin/bash
# The view's keys build 58 added — Roll Left and Right, Align View to Active,
# Zoom Region — held to Blender 5.2.1's numbers (tests/view/main.swift).
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-view-tests"
mkdir -p "$BUILD"
UI=Sources/BlenderLocalUI/Viewport
swiftc -O -o "$BUILD/run" \
  Sources/BlenderLocalBridge/*.swift \
  "$UI/ViewportCamera.swift" "$UI/ViewportOptions.swift" "$UI/ZoomRegion.swift" \
  "$UI/TransformGizmo.swift" "$UI/TransformGizmoGeometry.swift" \
  tests/gizmo/stub.swift \
  tests/view/main.swift
exec "$BUILD/run"
