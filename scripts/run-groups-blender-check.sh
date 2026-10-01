#!/bin/bash
# Vertex groups and shape keys, run the way the iPad runs them: Blender in
# background mode, factory settings, an undo stack as the app makes one.
#
# Every string the Data tab's Vertex Groups and Shape Keys panels send, and
# every modifier's Vertex Group edit (printed by tests/groups/blender/main.swift),
# is run by desktop Blender through the module the app ships; verify.py holds
# Blender's state to what each control means, checks the refusals are words
# and what one Undo takes back, then the Swift reads the records Blender's own
# mirror code produced and checks the panels would show what Blender held.
#
# Blender gets a home of its own: nothing here may write this Mac's settings.
# Skipped, not failed, when Blender is not installed.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
BUILD="${TMPDIR:-/tmp}/blenderlocal-groups-blender"
mkdir -p "$BUILD"
export HOME="$BUILD/home" BLENDER_USER_RESOURCES="$BUILD/home/res"
mkdir -p "$HOME"
swiftc -O -o "$BUILD/dump" Sources/BlenderLocalBridge/*.swift tests/groups/blender/main.swift
"$BUILD/dump" > "$BUILD/calls.txt"
echo "  $(grep -c '^### ' "$BUILD/calls.txt") strings from the Swift, put through Blender $("$BLENDER" --version | head -1 | cut -d' ' -f2)"
"$BLENDER" -b --factory-startup --python-exit-code 1 \
  --python tests/groups/blender/verify.py -- "$BUILD/calls.txt" "$BUILD/replay.json" 2>&1 \
  | grep -vE '^(Blender [0-9]|Read prefs|$)'
[ "${PIPESTATUS[0]}" -eq 0 ] || exit 1
exec "$BUILD/dump" replay "$BUILD/replay.json"
