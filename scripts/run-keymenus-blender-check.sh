#!/bin/bash
# The keys build 58 added that Blender runs — Fill (Alt+F), Triangulate Faces
# at Fixed and Clip (Shift+Ctrl+T), Ctrl+G's Vertex Groups rows, K's Insert
# Keyframe Menu and Ctrl+M's Interactive Mirror — run the way the iPad runs
# them: Blender in background mode, factory settings, no 3D View area in the
# context. What Blender runs is what the Swift sends (tests/keymenus/blender/
# main.swift), each result held to Blender's own operator.
#
# Skipped, not failed, when Blender is not installed.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
BUILD="${TMPDIR:-/tmp}/blenderlocal-keymenus-blender"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/dump" Sources/BlenderLocalBridge/*.swift tests/keymenus/blender/main.swift
"$BUILD/dump" > "$BUILD/calls.txt"
# A HOME and BLENDER_USER_RESOURCES of its own, as every Blender check has.
home="$BUILD/home"
mkdir -p "$home"
HOME="$home" BLENDER_USER_RESOURCES="$home/res" "$BLENDER" -b --factory-startup --python-exit-code 1 \
  --python tests/keymenus/blender/verify.py -- "$BUILD/calls.txt"
