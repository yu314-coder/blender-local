#!/bin/bash
# The Render panel's decisions and the camera view, on the Mac: what the panel
# asks Blender for, where the file goes, and what looking through a camera does
# to the 3D View. Blender itself runs the same requests in
# scripts/run-render-blender-check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-render-tests"
mkdir -p "$BUILD"
UI="Sources/BlenderLocalUI/Viewport"
swiftc -O -o "$BUILD/run" Sources/BlenderLocalBridge/*.swift \
  "$UI/ViewportCamera.swift" "$UI/ViewportOptions.swift" \
  "$UI/TransformGizmo.swift" "$UI/TransformGizmoGeometry.swift" \
  tests/gizmo/stub.swift tests/render/main.swift
exec "$BUILD/run"
