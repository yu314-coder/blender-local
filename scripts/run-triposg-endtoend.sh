#!/bin/bash
# Image to 3D Model's full 3D mode end to end on this Mac: the Swift/Metal
# TripoSG, the surface, desktop Blender running the app's prepare_full, the
# Swift viewpoint fit and bake, and finish_full, with renders from four sides.
#   BK_TRIPOSG_WEIGHTS=/path/TripoSG ./scripts/run-triposg-endtoend.sh <cut-out.png> <out dir>
# Skipped, not failed, without the weights or Blender.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ -z "${BK_TRIPOSG_WEIGHTS:-}" ] || [ ! -d "${BK_TRIPOSG_WEIGHTS:-}" ] || [ ! -x "$BLENDER" ]; then
  echo "  SKIP  set BK_TRIPOSG_WEIGHTS to a folder with TripoSG's weights (and install Blender)"; exit 0
fi
PICTURE="$1"; OUT="$2"; NAME="$(basename "${PICTURE%.*}")"
BUILD="${TMPDIR:-/tmp}/blenderlocal-triposg-endtoend"; mkdir -p "$BUILD" "$OUT"
swiftc -O -o "$BUILD/run" Sources/BlenderLocalBridge/*.swift tests/triposg/endtoend/main.swift
FOLDER="$OUT/$NAME"; rm -rf "$FOLDER"
"$BUILD/run" shape "$BK_TRIPOSG_WEIGHTS" "$PICTURE" "$FOLDER"
"$BLENDER" -b --factory-startup --python tests/triposg/endtoend/blender.py -- prepare "$FOLDER" 2>&1 | grep '\[e2e\]'
"$BUILD/run" bake "$FOLDER"
"$BLENDER" -b --factory-startup --python tests/triposg/endtoend/blender.py -- finish "$FOLDER" "$NAME" "$OUT/renders" 2>&1 | grep '\[e2e\]'
