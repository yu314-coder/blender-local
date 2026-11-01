#!/bin/bash
# The Mesh menu's round-4 rows held to Blender itself
# (tests/meshmenu/blender/verify.py): every row's first press, as the bridge
# sends it, does what Blender's own operator does on the same selection, and
# refuses in words where Blender would do nothing; Extrude to Cursor or Add and
# Rip Vertices and Extend make what Blender's own invokes make with the pointer
# over the 3D cursor (run in desktop with a made event, which only this check
# does), each with negative controls; and the rows the menu cannot run are
# measured changing nothing.
#
# Blender gets a home of its own under TMPDIR, as the other checks' do:
# nothing it runs writes into this Mac's own Blender settings.
#
# Skipped, not failed, when Blender is not installed.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
BUILD="${TMPDIR:-/tmp}/blenderlocal-meshmenu-blender"
home="$BUILD/home"
rm -rf "$BUILD/work"
mkdir -p "$BUILD" "$home" "$BUILD/work"
swiftc -O -o "$BUILD/dump" Sources/BlenderLocalBridge/*.swift tests/meshmenu/blender/main.swift
"$BUILD/dump" > "$BUILD/calls.txt"
echo "  $(grep -c '^###' "$BUILD/calls.txt") blocks to put through Blender $("$BLENDER" --version | head -1 | cut -d' ' -f2)"
set +e
HOME="$home" BLENDER_USER_RESOURCES="$home/res" \
  "$BLENDER" -b --factory-startup --python-exit-code 1 --python tests/meshmenu/blender/verify.py -- \
  "$BUILD/calls.txt" "$BUILD/work" 2>&1 \
  | grep -E "^  (PASS|FAIL)|^[A-Z][a-z].*$|^[0-9]+ passed|^ALL PASS|FAILED$|Error|Traceback" \
  | grep -vE '^(Blender [0-9]|Read prefs|Writing:|Warning:|Info:)'
status=${PIPESTATUS[0]}
set -e
exit "$status"
