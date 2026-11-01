#!/bin/bash
# The Render panel's own Python, run the way the iPad runs it: Blender 5.2.1 in
# background mode, factory settings, no 3D View area.
#
# It renders through the scene's camera and from the 3D View, and holds the
# second one to the first: Blender is asked where world points land in the
# picture, and must agree with the app's own projection. It also checks that a
# view render leaves no camera behind — including when the render fails — and
# that the camera menu items and the light and camera property writes land
# where Blender keeps them.
#
# Skipped, not failed, when Blender is not installed.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/blenderlocal-render-blender.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
UI="Sources/BlenderLocalUI/Viewport"
swiftc -O -o "$BUILD/dump" Sources/BlenderLocalBridge/*.swift \
  "$UI/ViewportCamera.swift" "$UI/ViewportOptions.swift" \
  "$UI/TransformGizmo.swift" "$UI/TransformGizmoGeometry.swift" \
  tests/gizmo/stub.swift tests/render/blender/main.swift
"$BUILD/dump" > "$BUILD/calls.txt"
# Blender gets a HOME and BLENDER_USER_RESOURCES of its own: even a bare
# `-b --factory-startup` run writes ~/.thumbnails into HOME (measured), and an
# operator can write Blender's settings. Other checks run at the same time.
home="$BUILD/home"
mkdir -p "$home"
echo "== Blender $("$BLENDER" --version | head -1 | cut -d' ' -f2), headless"
exec env HOME="$home" BLENDER_USER_RESOURCES="$home/res" "$BLENDER" -b --factory-startup --python-exit-code 1 \
  --python tests/render/blender/verify.py -- "$BUILD/calls.txt" "$BUILD" 2>&1 \
  | grep -v "^Blender quit\|^Read prefs\|^Fra:\|^Saved:\|Blender 5\|^$"
