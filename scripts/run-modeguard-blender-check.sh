#!/bin/bash
# Every raw operator the 3D View's menus send, bracketed by BpyModeGuard, run
# in desktop Blender from each of the three modes a session can be left in.
#
# Without the guard all of them failed their poll in two of the three modes —
# select, delete, extrude, normals, UV unwrap. With it, each must run from any
# starting mode and hand back the mode it found.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
[ -x "$BLENDER" ] || { echo "  SKIP  desktop Blender not installed"; exit 0; }
BUILD="${TMPDIR:-/tmp}/blenderlocal-modeguard-blender"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/dump" Sources/BlenderLocalBridge/*.swift tests/modeguard/blender/main.swift
"$BUILD/dump" > "$BUILD/calls.txt"
exec python3 tests/modeguard/blender/drive.py "$BUILD/calls.txt"
