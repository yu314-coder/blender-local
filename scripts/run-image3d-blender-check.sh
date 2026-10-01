#!/bin/bash
# Image to 3D Model in Blender background mode: the folders ImageToModel.swift
# writes and the Python the app sends, run through _blenderkit_image3d.py —
# mesh, UVs, the material the viewport reads its texture through, and the
# packed picture surviving a save and reload.
#
# Its files go in a private temporary directory. Skipped, not failed, when
# Blender is not installed.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/blenderlocal-image3d-blender.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
swiftc -O -o "$WORK/dump" Sources/BlenderLocalBridge/*.swift tests/image3d/blender/main.swift
"$WORK/dump" "$WORK" > "$WORK/calls.txt"
"$BLENDER" -b --factory-startup --python-exit-code 1 \
  --python tests/image3d/blender/verify.py -- "$WORK/calls.txt" "$WORK" 2>&1 \
  | grep -vE '^(Blender [0-9]|Read prefs|Read blend|Info: Saved|Saved "|$)'
exit "${PIPESTATUS[0]}"
