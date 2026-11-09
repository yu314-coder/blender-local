#!/bin/bash
# The Timeline's key and marker editing, run the way the iPad runs it:
# Blender in background mode, factory settings, no area in the context, the
# startup screen's Timeline borrowed for Blender's own operators. What runs is
# what the Swift sends (tests/timeline/blender/main.swift). Each edit is held
# to Blender's own operator on a twin of the scene, or to Blender's rules
# where it works by frame; the report the timeline draws from; one undo step
# an edit through the app's history, undone and redone; and the menus' rows
# against Blender's menus as their draw() lays them out.
#
# Blender 5.2.1 must be installed; skipped, not failed, when it is not. Builds
# and writes only inside a private temporary directory.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/blenderlocal-timeline-blender.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
swiftc -O -o "$BUILD/dump" Sources/BlenderLocalBridge/*.swift tests/timeline/blender/main.swift
"$BUILD/dump" > "$BUILD/calls.txt"
"$BUILD/dump" menus > "$BUILD/menus.json"
echo "  $(grep -c '^###' "$BUILD/calls.txt") strings from the Swift, put through Blender $("$BLENDER" --version | head -1 | cut -d' ' -f2)"
mkdir -p "$BUILD/home/res" "$BUILD/work" "$BUILD/tmp"
ROOT="$(pwd)"
cd "$BUILD"
HOME="$BUILD/home" BLENDER_USER_RESOURCES="$BUILD/home/res" TMPDIR="$BUILD/tmp" \
  "$BLENDER" -b --factory-startup --python-exit-code 1 --python "$ROOT/tests/timeline/blender/verify.py" -- \
  "$BUILD/calls.txt" "$BUILD/work" "$BUILD/menus.json" 2>&1 \
  | grep -E '^  (PASS|FAIL|SKIP)|^\S.*[a-z].*$|^ +(app|blender):|ALL PASS|FAILED$|Error|Traceback|^  File' \
  | grep -v '^Blender \|^Read \|^Writing' 
exit "${PIPESTATUS[0]}"
