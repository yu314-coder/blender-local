#!/bin/bash
# Edit Mode on curves and lattices, run the way the iPad runs it: Blender in
# background mode, factory settings, no 3D View area in the context.
#
# fixtures.py builds a Bézier circle, a Bézier curve, a NURBS path and a lattice
# deforming the cube, and hands the Swift their control points as
# `_blenderkit_points.cage` reads them. The Swift (main.swift) reads those
# through `SceneMirror.carryPoints`, then prints every string the 3D View sends
# for them — taps, a box, a real gizmo session's frames and commit, the Curve
# and Lattice menus, the Data tab, Add ▸ Lattice. verify.py runs each in
# Blender and holds Blender's state to what the Swift expected; what Blender
# then pushes back is replayed through the Swift.
#
# Blender gets a home of its own: nothing here may write this Mac's settings.
# Skipped, not failed, when Blender is not installed.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
BUILD="${TMPDIR:-/tmp}/blenderlocal-points-blender"
mkdir -p "$BUILD"
export HOME="$BUILD/home" BLENDER_USER_RESOURCES="$BUILD/home/res"
mkdir -p "$HOME"
swiftc -O -o "$BUILD/dump" \
  Sources/BlenderLocalBridge/*.swift \
  Sources/BlenderLocalUI/Viewport/ViewportCamera.swift \
  Sources/BlenderLocalUI/Viewport/ViewportOptions.swift \
  Sources/BlenderLocalUI/Viewport/TransformGizmo.swift \
  Sources/BlenderLocalUI/Viewport/TransformGizmoGeometry.swift \
  tests/gizmo/stub.swift \
  tests/points/blender/main.swift
# Nothing from an earlier run may stand in for this one's: a fixtures.py that
# failed used to leave the last run's cages.json for the dump to pass against,
# its Traceback piped through `grep … || true`.
rm -f "$BUILD/cages.json" "$BUILD/calls.txt" "$BUILD/replay.json"
if ! "$BLENDER" -b --factory-startup --python-exit-code 1 \
    --python tests/points/blender/fixtures.py -- "$BUILD/cages.json" > "$BUILD/fixtures.log" 2>&1; then
  grep -E "Error|Traceback|File " "$BUILD/fixtures.log" || tail -20 "$BUILD/fixtures.log"
  echo "  FAIL  fixtures.py"
  exit 1
fi
grep -E "^wrote" "$BUILD/fixtures.log"
if [ ! -s "$BUILD/cages.json" ]; then
  echo "  FAIL  fixtures.py wrote no cages"
  exit 1
fi
"$BUILD/dump" "$BUILD/cages.json" > "$BUILD/calls.txt"
"$BLENDER" -b --factory-startup --python-exit-code 1 \
  --python tests/points/blender/verify.py -- "$BUILD/calls.txt" "$BUILD/replay.json"
"$BUILD/dump" replay "$BUILD/replay.json"
