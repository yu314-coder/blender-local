#!/bin/bash
# Box, Circle and Lasso select, and the Select menu, against desktop Blender
# 5.2.1 — the version the app embeds.
#
#   1. Blender's own view3d.select_box / select_circle / select_lasso, X-Ray on
#      (without it they select nothing without a window), over a grid, a cube
#      and a sphere in vertex, edge and face mode (verify.py measure);
#   2. the app's Swift pass over the same regions in the same view, compared
#      element by element (main.swift);
#   3. what the app then sends Blender — each selection pushed as it pushes
#      it, and every Select menu row — run and read back (verify.py apply).
#
# The Blender it starts gets a HOME and BLENDER_USER_RESOURCES of its own, so
# nothing it does reaches this Mac's Blender settings, and nothing here opens
# a browser or another program. Skipped, not failed, without Blender.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
BUILD="${TMPDIR:-/tmp}/blenderlocal-regionselect-blender"
mkdir -p "$BUILD/home" "$BUILD/resources"
export HOME="$BUILD/home" BLENDER_USER_RESOURCES="$BUILD/resources"
swiftc -O -o "$BUILD/run" Sources/BlenderLocalBridge/*.swift tests/regionselect/blender/main.swift
"$BLENDER" -b --factory-startup --python-exit-code 1 \
  --python tests/regionselect/blender/verify.py -- measure "$BUILD/scenes.json" 2>&1 | grep -v "^Blender quit\|^$" || true
[ -s "$BUILD/scenes.json" ] || { echo "  FAIL  Blender wrote no measurements"; exit 1; }
status=0
"$BUILD/run" "$BUILD/scenes.json" "$BUILD/calls.txt" || status=1
"$BLENDER" -b --factory-startup --python-exit-code 1 \
  --python tests/regionselect/blender/verify.py -- apply "$BUILD/calls.txt" || status=1
exit $status
