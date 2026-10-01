#!/bin/bash
# Mirror editing — the mesh's X / Y / Z symmetry and Topology Mirror — run the
# way the iPad runs it: Blender in background mode, factory settings, no 3D
# View area, so a transform mirrors only when it is sent `mirror=True`.
#
# Three steps: Blender writes out its meshes and the flag strings its mirror
# sends; the Swift previews every drag on exactly those meshes, with the
# symmetry as the mirror installs it, and prints the Python and the result;
# Blender runs the Python and compares. Also the header's toggles, the Mesh
# menu's transforms, and Topology Mirror's pairs against Blender's own.
#
# Skipped, not failed, when Blender is not installed.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
BUILD="${TMPDIR:-/tmp}/blenderlocal-symmetry-blender"
mkdir -p "$BUILD"
# A home of its own, so nothing Blender writes lands in this Mac's settings.
export HOME="$BUILD/home" BLENDER_USER_RESOURCES="$BUILD/home/res"
mkdir -p "$HOME"
swiftc -O -o "$BUILD/dump" \
  Sources/BlenderLocalBridge/*.swift \
  Sources/BlenderLocalUI/Viewport/ViewportCamera.swift \
  Sources/BlenderLocalUI/Viewport/ViewportOptions.swift \
  Sources/BlenderLocalUI/Viewport/TransformGizmo.swift \
  Sources/BlenderLocalUI/Viewport/TransformGizmoGeometry.swift \
  tests/gizmo/stub.swift \
  tests/symmetry/blender/main.swift
"$BLENDER" -b --factory-startup --python-exit-code 1 \
  --python tests/symmetry/blender/meshes.py -- "$BUILD/meshes.json" \
  | grep -E "wrote|Error|Traceback" || true
"$BUILD/dump" "$BUILD/meshes.json" > "$BUILD/calls.txt"
exec "$BLENDER" -b --factory-startup --python-exit-code 1 \
  --python tests/symmetry/blender/verify.py -- "$BUILD/calls.txt"
