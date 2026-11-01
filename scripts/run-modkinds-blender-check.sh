#!/bin/bash
# Round 4, group 8, run the way the iPad runs it: Blender's whole Add Modifier
# menu by object type, the eleven declared modifier rows and their buttons,
# the vertex budget for what makes geometry, a text object's Body Text and
# Data tab rows, and Add ▸ Image's reference and background pictures. Blender
# in background mode, factory settings, no 3D View area in the context (the
# app borrows the startup screen's where it does), and Blender's undo started
# through the app's own `_blenderkit_undo`, as the app starts it.
#
# Two Blender runs: the first holds the catalog to Blender's own menus, adds
# every row, measures the budget and writes Blender's record of each declared
# row; the Swift builds each row's edits from that record; the second runs
# them, the buttons, the text and the pictures, and writes what Blender
# reported, which the Swift replays as the panels read it.
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
WORK="$(mktemp -d "${TMPDIR:-/tmp}/blenderlocal-modkinds-blender.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Documents" "$WORK/home"
swiftc -O -o "$WORK/dump" Sources/BlenderLocalBridge/*.swift tests/modkinds/pictures.swift tests/modkinds/blender/main.swift
"$WORK/dump" calls > "$WORK/calls.txt"
echo "  $(grep -c '^###' "$WORK/calls.txt") strings from the Swift, put through Blender $("$BLENDER" --version | head -1 | cut -d' ' -f2)"
HOME="$WORK/home" BLENDER_USER_RESOURCES="$WORK/home/res" \
  "$BLENDER" -b --factory-startup --python-exit-code 1 \
  --python tests/modkinds/blender/verify.py -- 1 "$WORK/calls.txt" "$WORK/records.json" "$WORK"
"$WORK/dump" edits "$WORK/records.json" > "$WORK/edits.txt"
"$WORK/dump" pictures "$WORK/pictures"
cat "$WORK/calls.txt" "$WORK/edits.txt" > "$WORK/all.txt"
echo "  $(grep -c '^###EDIT' "$WORK/edits.txt") edits built from Blender's record"
HOME="$WORK/home" BLENDER_USER_RESOURCES="$WORK/home/res" \
  "$BLENDER" -b --factory-startup --python-exit-code 1 \
  --python tests/modkinds/blender/verify.py -- 2 "$WORK/all.txt" "$WORK/passes.json" "$WORK"
"$WORK/dump" replay "$WORK/passes.json"
