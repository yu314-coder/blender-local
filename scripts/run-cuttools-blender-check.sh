#!/bin/bash
# Loop Cut and the Knife held to Blender itself (tests/cuttools/blender/verify.py):
# the ring the viewport previews is the ring Blender's loop cut cuts, on every
# edge of nine meshes; the calls the app sends cut as Blender does and refuse
# in words what would crash or silently do nothing; the Knife's cut lands on
# the crossings its path makes. Then the Swift half (main.swift preview) draws
# each preview from Blender's ring and holds it to the cut Blender made, and
# a preview drawn without Blender's orientation must fail.
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
BUILD="${TMPDIR:-/tmp}/blenderlocal-cuttools-blender"
home="$BUILD/home"
mkdir -p "$BUILD" "$home"
swiftc -O -o "$BUILD/dump" Sources/BlenderLocalBridge/*.swift tests/cuttools/blender/main.swift
"$BUILD/dump" dump > "$BUILD/calls.txt"
echo "  $(grep -c '^###' "$BUILD/calls.txt") blocks to put through Blender $("$BLENDER" --version | head -1 | cut -d' ' -f2)"
set +e
# From the build folder, not the repo: what Blender writes into its working
# folder stays out of the tree.
ROOT="$(pwd)"
cd "$BUILD"
HOME="$home" BLENDER_USER_RESOURCES="$home/res" \
  "$BLENDER" -b --factory-startup --python-exit-code 1 --python "$ROOT/tests/cuttools/blender/verify.py" -- \
  "$BUILD/calls.txt" "$BUILD/fixtures.json" 2>&1 \
  | grep -E "^  (PASS|FAIL)|^[A-Z][a-z].*$|^ALL PASS|FAILED$|Error|Traceback" | grep -vE '^(Blender [0-9]|Read prefs|Writing:)'
status=${PIPESTATUS[0]}
cd "$ROOT"
set -e
[ "$status" -eq 0 ] || exit "$status"
echo
echo "The preview the viewport draws from Blender's ring, held to the cut"
"$BUILD/dump" preview "$BUILD/fixtures.json"
echo
echo "The negative control: the same previews drawn without Blender's orientation"
if "$BUILD/dump" preview "$BUILD/fixtures.json" --negative > "$BUILD/negative.txt"; then
  echo "  FAIL  the preview check could not fail"; exit 1
else
  grep -c "FAIL" "$BUILD/negative.txt" | sed 's/^/  PASS  it fails: /; s/$/ meshes and counts differ/'
fi
