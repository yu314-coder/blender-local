#!/bin/bash
# Properties ▸ Material, run the way the iPad runs it: Blender in background
# mode, factory settings, no area, an undo stack as the app makes one.
#
# Every string the Material tab sends (printed by tests/material/blender/main.swift)
# is run by desktop Blender through the module the app ships; verify.py holds
# Blender's state to what each control means — the slots, Assign in Edit
# Mode, New, Unlink, Make Single User, the shader swap, every Principled BSDF
# input (sRGB picked, linear held), the Settings — checks the refusals are
# words and what one Undo takes back, then the Swift reads the tab's states
# and the mirror's looks back and checks they show what Blender held.
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
BUILD="${TMPDIR:-/tmp}/blenderlocal-material-blender"
mkdir -p "$BUILD/work"
export HOME="$BUILD/home" BLENDER_USER_RESOURCES="$BUILD/home/res" TMPDIR="$BUILD/work"
mkdir -p "$HOME"
swiftc -O -o "$BUILD/dump" Sources/BlenderLocalBridge/*.swift tests/material/blender/main.swift
"$BUILD/dump" > "$BUILD/calls.txt"
echo "  $(grep -c '^### ' "$BUILD/calls.txt") strings from the Swift, put through Blender $("$BLENDER" --version | head -1 | cut -d' ' -f2)"
"$BLENDER" -b --factory-startup --python-exit-code 1 \
  --python tests/material/blender/verify.py -- "$BUILD/calls.txt" "$BUILD/replay.json" "$BUILD/dump" "$BUILD/work" 2>&1 \
  | grep -vE '^(Blender [0-9]|Read prefs|$|Info: )'
[ "${PIPESTATUS[0]}" -eq 0 ] || exit 1
exec "$BUILD/dump" replay "$BUILD/replay.json"
