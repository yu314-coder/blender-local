#!/bin/bash
# The gizmo's maths is pure Swift over simd, so it can be exercised on the Mac
# without a simulator, a device or Metal. Everything visual still needs a
# screenshot; this covers the part that silently goes wrong.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-gizmo-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" \
  Sources/BlenderLocalBridge/*.swift \
  Sources/BlenderLocalUI/Viewport/ViewportCamera.swift \
  Sources/BlenderLocalUI/Viewport/ViewportOptions.swift \
  Sources/BlenderLocalUI/Viewport/TransformGizmo.swift \
  Sources/BlenderLocalUI/Viewport/TransformGizmoGeometry.swift \
  tests/gizmo/stub.swift \
  tests/gizmo/main.swift
exec "$BUILD/run"
