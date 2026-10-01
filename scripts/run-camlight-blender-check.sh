#!/bin/bash
# Cameras, lights and empties, run the way the iPad runs them: Blender 5.2.1 in
# background mode, factory settings, no 3D View area.
#
# Three stages:
#   1. verify.py runs what the Swift sends — the Add operators from any mode and
#      re-run by the redo panel, a tap, the gizmo's transforms, Delete, Duplicate,
#      box select — and the mirror itself, checking every record against bpy.
#      It writes Blender's own camera frames and the scenario's records.
#   2. The Swift overlay code is held to those frames.
#   3. The simulator's shim runs the same scenario and is held to those records.
#
# Skipped, not failed, when Blender is not installed. Everything is built and
# written in a private temporary directory, so other checks running at the
# same time cannot trip over it.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi

BUILD="$(mktemp -d "${TMPDIR:-/tmp}/blenderlocal-camlight-blender.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT

UI="Sources/BlenderLocalUI/Viewport"
swiftc -O -o "$BUILD/dump" \
  Sources/BlenderLocalBridge/*.swift \
  "$UI/ViewportCamera.swift" "$UI/ViewportOptions.swift" \
  "$UI/TransformGizmo.swift" "$UI/TransformGizmoGeometry.swift" \
  tests/gizmo/stub.swift \
  tests/camlight/blender/main.swift
swiftc -O -o "$BUILD/geometry" \
  Sources/BlenderLocalBridge/*.swift \
  "$UI/ViewportCamera.swift" \
  tests/camlight/blender/geometry/main.swift
"$BUILD/dump" > "$BUILD/calls.txt"

PYTHON=""
for candidate in /opt/homebrew/bin/python3.* /usr/local/bin/python3.*; do
  case "$candidate" in *-config) continue ;; esac
  [ -x "$candidate" ] && PYTHON="$candidate"
done
[ -n "$PYTHON" ] || PYTHON=python3

status=0
echo "== Blender $("$BLENDER" --version | head -1 | cut -d' ' -f2), headless"
"$BLENDER" -b --factory-startup --python-exit-code 1 \
  --python tests/camlight/blender/verify.py -- "$BUILD/calls.txt" "$BUILD" || status=1
echo
echo "== the overlay code against Blender's frames"
"$BUILD/geometry" "$BUILD/frames.json" "$BUILD/records.json" || status=1
echo
echo "== the simulator's shim against Blender's records"
"$PYTHON" -B tests/camlight/shim/main.py "$BUILD/calls.txt" "$BUILD/records.json" || status=1
exit $status
