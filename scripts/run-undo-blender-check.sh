#!/bin/bash
# Undo on the device, run the way the iPad runs it: Blender in background mode,
# factory settings, no 3D View area.
#
# What it checks is what the Swift sends, printed by
# tests/undo/blender/main.swift, through the modules the app ships: the probe;
# every kind of step — add, delete, transform, modifier, edit-mode operators,
# mode and selection, a Texture Paint stroke, animation keys, camera and light
# settings — undone and redone to the vertex and the pixel; adjusting the last
# operation by undo, re-run and push; Run Script as one step, including one
# that loads a file; the step limit; the checkpoint fallback, forced and after
# a failure; the recovery file; and what each costs.
#
# Its files go in a private temporary directory, since other checks run at the
# same time. Skipped, not failed, when Blender is not installed.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/blenderlocal-undo-blender.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Documents"
swiftc -O -o "$WORK/dump" Sources/BlenderLocalBridge/*.swift tests/undo/blender/main.swift
"$WORK/dump" > "$WORK/calls.txt"
echo "  $(grep -c '^###' "$WORK/calls.txt") strings from the Swift, put through Blender $("$BLENDER" --version | head -1 | cut -d' ' -f2)"
"$BLENDER" -b --factory-startup --python-exit-code 1 \
  --python tests/undo/blender/verify.py -- "$WORK/calls.txt" "$WORK"
