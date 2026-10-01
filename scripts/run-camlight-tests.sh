#!/bin/bash
# Cameras, lights and empties, on the Mac.
#
# First the Swift: the record they travel in, the lines Blender's overlays draw
# for them, tapping and box-selecting them, the transform tools taking hold of
# them, the Add operators, and keeping them through duplicate, undo and paste.
# Then the simulator's shim, run with a stand-in for the app's _blenderkit over
# the same Python the interface sends.
#
# What Blender itself makes of all of it: scripts/run-camlight-blender-check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD="$(mktemp -d "${TMPDIR:-/tmp}/blenderlocal-camlight-tests.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT

UI="Sources/BlenderLocalUI/Viewport"
swiftc -O -o "$BUILD/run" \
  Sources/BlenderLocalBridge/*.swift \
  "$UI/ViewportCamera.swift" "$UI/ViewportOptions.swift" \
  "$UI/TransformGizmo.swift" "$UI/TransformGizmoGeometry.swift" \
  tests/gizmo/stub.swift \
  tests/camlight/main.swift
swiftc -O -o "$BUILD/dump" \
  Sources/BlenderLocalBridge/*.swift \
  "$UI/ViewportCamera.swift" "$UI/ViewportOptions.swift" \
  "$UI/TransformGizmo.swift" "$UI/TransformGizmoGeometry.swift" \
  tests/gizmo/stub.swift \
  tests/camlight/blender/main.swift

# The newest python3 here: the app embeds 3.14.
PYTHON=""
for candidate in /opt/homebrew/bin/python3.* /usr/local/bin/python3.*; do
  case "$candidate" in *-config) continue ;; esac
  [ -x "$candidate" ] && PYTHON="$candidate"
done
[ -n "$PYTHON" ] || PYTHON=python3

status=0
echo "== Swift"
"$BUILD/run" || status=1
"$BUILD/dump" > "$BUILD/calls.txt"
echo
echo "== the shim ($("$PYTHON" --version))"
"$PYTHON" -B tests/camlight/shim/main.py "$BUILD/calls.txt" || status=1
exit $status
