#!/bin/bash
# Round 4, group 7, run the way the iPad runs it: the Outliner's collections,
# Object ▸ Collection, the Object Constraints tab, the Object menu's Mirror,
# Link/Transfer Data, Make Single User, Copy Modifiers to Selected Objects,
# Randomize Transform and Align Objects rows, and Local View. Blender in
# background mode, factory settings, no 3D View area in the context (the app
# borrows the startup screen's where it does), and Blender's undo started
# through the app's own `_blenderkit_undo`, as the app starts it.
#
# What Blender runs is what the Swift sends; each row is held to Blender's own
# operator as its menu row calls it, on the same fixture, and to the step
# Blender's history records for it. After the steps that change what the
# Outliner, the tab or the viewport shows, the app's own _blenderkit_sync.py
# pushes the scene and the Swift the device runs rebuilds it.
#
# Its undo history goes in a private temporary directory. Nothing here opens a
# window, a browser or another app, and Blender's own settings are not read or
# written (--factory-startup, and a HOME of its own). Skipped, not failed, when
# Blender is not installed.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/blenderlocal-relations-blender.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Documents" "$WORK/home"
swiftc -O -o "$WORK/dump" Sources/BlenderLocalBridge/*.swift tests/relations/blender/main.swift
"$WORK/dump" > "$WORK/calls.txt"
echo "  $(grep -c '^###' "$WORK/calls.txt") strings from the Swift, put through Blender $("$BLENDER" --version | head -1 | cut -d' ' -f2)"
HOME="$WORK/home" BLENDER_USER_RESOURCES="$WORK/home/res" \
  "$BLENDER" -b --factory-startup --python-exit-code 1 \
  --python tests/relations/blender/verify.py -- "$WORK/calls.txt" "$WORK/passes.json" "$WORK"
"$WORK/dump" "$WORK/passes.json"
