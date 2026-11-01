#!/bin/bash
# The normals the 3D View shades a mesh with, run the way the iPad runs them:
# desktop Blender with the app's context, the app's own _blenderkit_sync.py
# and _blenderkit_anim.push_mesh pushing a scene, and the Swift the device runs
# installing what they pushed (tests/shading/blender/main.swift), every
# triangle corner held to the corner normals Blender's Solid view draws. The
# scene: the Mesh menu's six Normals rows, each by its own first press, a
# primitive's flat faces, Shade Smooth and Shade Flat, Shade Smooth by Angle,
# Edit Mode with a hidden face, and a frame change. The control replays the
# same passes without sync_shading.
#
# Blender gets a home of its own under TMPDIR, as the other checks' do.
# Skipped, not failed, when Blender is not installed.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
BUILD="${TMPDIR:-/tmp}/blenderlocal-shading-blender"
home="$BUILD/home"
mkdir -p "$BUILD" "$home"
swiftc -O -o "$BUILD/dump" Sources/BlenderLocalBridge/*.swift tests/shading/blender/main.swift
"$BUILD/dump" > "$BUILD/calls.txt"
HOME="$home" BLENDER_USER_RESOURCES="$home/res" \
  "$BLENDER" -b --factory-startup --python-exit-code 1 --python tests/shading/blender/verify.py -- \
  "$BUILD/calls.txt" "$BUILD/passes.json" 2>&1 \
  | grep -E "^  (PASS|FAIL)|passes written|Error|Traceback|^  File" || true
test -s "$BUILD/passes.json"
exec "$BUILD/dump" "$BUILD/passes.json"
