#!/bin/bash
# The Cursor tool, the Measure tool's ruler and Edit Mode's Statistics and
# Measurement overlays against desktop Blender 5.2.1, the version the app
# embeds (tests/measure/blender/verify.py):
#
#   1. Blender's own Cursor tool (`view3d.cursor3d`'s invoke, with a made
#      event) at pixels of five fixtures and four views, for both Surface
#      Projects, every Orientation and four rotation modes, the cursor in
#      front of the view and behind it (verify.py measure);
#   2. the app's hits on the mirror at those pixels and the calls a tap makes,
#      and the strings, rulers and labels the Swift draws (main.swift);
#   3. those calls run in Blender with the app's context and held to
#      Blender's own result, with negative controls; no undo step, and
#      Blender's undo keeping the cursor (verify.py apply).
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
BUILD="${TMPDIR:-/tmp}/blenderlocal-measure-blender"
rm -rf "$BUILD/history"
mkdir -p "$BUILD/home" "$BUILD/resources" "$BUILD/history"
export HOME="$BUILD/home" BLENDER_USER_RESOURCES="$BUILD/resources" BK_WORK="$BUILD"
swiftc -O -o "$BUILD/run" Sources/BlenderLocalBridge/*.swift tests/measure/blender/main.swift
rm -f "$BUILD/scenes.json"
status=0
# The measure phase's own checks count too: its exit code is Blender's
# (--python-exit-code), read through the pipe. `|| true` here used to throw it
# away, so a FAIL it printed left the script passing (round 4's review).
set +e
"$BLENDER" -b --factory-startup --python-exit-code 1 \
  --python tests/measure/blender/verify.py -- measure "$BUILD/scenes.json" 2>&1 \
  | grep -E "^  (PASS|FAIL|measured)|Error|Traceback"
code=${PIPESTATUS[0]}
set -e
[ "$code" -eq 0 ] || { echo "  FAIL  the measure phase exited $code"; status=1; }
[ -s "$BUILD/scenes.json" ] || { echo "  FAIL  Blender wrote no measurements"; exit 1; }
"$BUILD/run" "$BUILD/scenes.json" "$BUILD/calls.txt" || status=1
rm -rf "$BUILD/history"; mkdir -p "$BUILD/history"
set +e
"$BLENDER" -b --factory-startup --python-exit-code 1 \
  --python tests/measure/blender/verify.py -- apply "$BUILD/scenes.json" "$BUILD/calls.txt" 2>&1 \
  | grep -E "^  (PASS|FAIL)|^  [0-9a-z]|^    |^[a-zA-Z].*$|^ALL PASS|FAILED|Error|Traceback" | grep -vE '^(Blender [0-9]|Read prefs|Writing:|Blender quit)'
code=${PIPESTATUS[0]}
set -e
[ "$code" -eq 0 ] || status=1
exit $status
