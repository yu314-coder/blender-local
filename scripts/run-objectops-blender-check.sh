#!/bin/bash
# Object ▸ Duplicate Linked, Join, Parent, Clear Parent and Convert, the Mesh
# menu's clean-up, split and extrude rows, Bevel Vertices, Inset Individual and
# Shear, run the way the iPad runs them: Blender in background mode, factory
# settings, no 3D View area in the context, and Blender's undo started through
# the app's own `_blenderkit_undo`, as the app starts it.
#
# What Blender runs is what `perform` sends, and a redo-panel change is the
# history's rewind and the operator again, as the panel does it. After the
# steps that change the Outliner, the app's own _blenderkit_sync.py pushes the
# scene, and the Swift the device runs builds it: the parent tree, the joined,
# duplicated and converted objects.
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
WORK="$(mktemp -d "${TMPDIR:-/tmp}/blenderlocal-objectops-blender.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Documents" "$WORK/home"
swiftc -O -o "$WORK/dump" Sources/BlenderLocalBridge/*.swift tests/objectops/blender/main.swift
"$WORK/dump" > "$WORK/calls.txt"
echo "  $(grep -c '^###' "$WORK/calls.txt") strings from the Swift, put through Blender $("$BLENDER" --version | head -1 | cut -d' ' -f2)"
HOME="$WORK/home" BLENDER_USER_RESOURCES="$WORK/home/res" \
  "$BLENDER" -b --factory-startup --python-exit-code 1 \
  --python tests/objectops/blender/verify.py -- "$WORK/calls.txt" "$WORK/passes.json" "$WORK"
"$WORK/dump" "$WORK/passes.json"
