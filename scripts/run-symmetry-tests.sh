#!/bin/bash
# Mirror editing on the Swift side: the flag the mirror carries, which
# vertices follow which (SymmetricEdit), Topology Mirror's pairs, what a drag
# previews and sends, and what the toggles and the Mesh menu send. Pure simd
# and strings; no Metal, no Python. Against Blender itself:
# scripts/run-symmetry-blender-check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-symmetry-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" \
  Sources/BlenderLocalBridge/*.swift \
  Sources/BlenderLocalUI/Viewport/ViewportCamera.swift \
  Sources/BlenderLocalUI/Viewport/ViewportOptions.swift \
  Sources/BlenderLocalUI/Viewport/TransformGizmo.swift \
  Sources/BlenderLocalUI/Viewport/TransformGizmoGeometry.swift \
  tests/gizmo/stub.swift \
  tests/symmetry/main.swift
exec "$BUILD/run"
