#!/bin/bash
# Blender's pick selections — Loop Select, Edge Ring Select, Pick Shortest
# Path, Select Linked — and the Select menu's new rows against desktop Blender
# 5.2.1, the version the app embeds (tests/selectpick/blender/verify.py):
#
#   1. Blender's own click at each visible element of a grid, a cube, a UV
#      sphere and a cylinder, X-Ray on, and what its Alt+click, Ctrl+Alt+click,
#      Ctrl+click and L do from that element (verify.py measure);
#   2. the app's pick at the same pixels — MeshPicker, Blender's index for it,
#      the active element, the call (main.swift);
#   3. those calls run in Blender with the app's context and held to Blender's
#      result, the refusals, Next/Previous Active, Side of Active, Select
#      Grouped, the selection order's round trip, the undo-in-an-area guard,
#      Select Linked ▸ Linked against Blender's own Ctrl+L per select mode,
#      Box Select's Set over the selection, and the negative controls
#      (verify.py apply).
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
BUILD="${TMPDIR:-/tmp}/blenderlocal-selectpick-blender"
mkdir -p "$BUILD/home" "$BUILD/resources"
export HOME="$BUILD/home" BLENDER_USER_RESOURCES="$BUILD/resources"
swiftc -O -o "$BUILD/run" Sources/BlenderLocalBridge/*.swift tests/selectpick/blender/main.swift
rm -f "$BUILD/scenes.json"
"$BLENDER" -b --factory-startup --python-exit-code 1 \
  --python tests/selectpick/blender/verify.py -- measure "$BUILD/scenes.json" 2>&1 \
  | grep -E "^  (PASS|FAIL|measured)|Error|Traceback" || true
[ -s "$BUILD/scenes.json" ] || { echo "  FAIL  Blender wrote no measurements"; exit 1; }
status=0
"$BUILD/run" "$BUILD/scenes.json" "$BUILD/calls.txt" || status=1
set +e
"$BLENDER" -b --factory-startup --python-exit-code 1 \
  --python tests/selectpick/blender/verify.py -- apply "$BUILD/scenes.json" "$BUILD/calls.txt" 2>&1 \
  | grep -E "^  (PASS|FAIL)|^[a-zA-Z].*$|^ALL PASS|FAILED$|Error|Traceback" | grep -vE '^(Blender [0-9]|Read prefs|Writing:|Blender quit)'
code=${PIPESTATUS[0]}
set -e
[ "$code" -eq 0 ] || status=1
exit $status
