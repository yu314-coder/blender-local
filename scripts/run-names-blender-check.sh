#!/bin/bash
# The app's names held to Blender itself (tests/names/blender/verify.py): each
# redo panel's title against its operator's name, each undo step against the
# step Blender's own history records for the same call (run with its undo on,
# in the app's context: its undo history, gpu.init()), each choice against its
# enum item, and the simulator's brushes against the Essentials library.
#
# Blender gets a home of its own under the work directory, so nothing it does
# reaches this Mac's Blender settings. Skipped, not failed, when Blender is not
# installed.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/blenderlocal-names-blender.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home/res" "$WORK/history"
swiftc -O -o "$WORK/dump" Sources/BlenderLocalBridge/*.swift tests/names/main.swift
"$WORK/dump" > "$WORK/names.json"
echo "  $(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))))" "$WORK/names.json") names from the Swift, put to Blender $("$BLENDER" --version | head -1 | cut -d' ' -f2)"
HOME="$WORK/home" BLENDER_USER_RESOURCES="$WORK/home/res" "$BLENDER" -b --factory-startup \
  --python-exit-code 1 --python tests/names/blender/verify.py -- "$WORK/names.json" "$WORK" 2>&1 \
  | grep -vE '^(Blender [0-9]|Read prefs|Writing:|Info: Saved copy|\[steps\] |$)'
status="${PIPESTATUS[0]}"
# The in-app measuring script's JSON from this Blender, held to the app's
# labels by the comparison the app's own run goes through
# (tests/names/app_steps_compare.py; docs/blender-names.md, "In the app").
if [ -f "$WORK/app-steps.json" ]; then
  python3 tests/names/app_steps_compare.py "$WORK/names.json" "$WORK/app-steps.json" | grep -v '^  PASS  [a-z_]*\.[a-z_:A-Z]*:' \
    || status=1
  [ "${PIPESTATUS[0]}" = 0 ] || status=1
else
  echo "  FAIL  app_steps.py wrote no measurement"; status=1
fi
exit "$status"
