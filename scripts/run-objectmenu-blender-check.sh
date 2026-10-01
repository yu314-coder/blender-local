#!/bin/bash
# Show/Hide, Separate, Shade Auto Smooth, QuadriFlow and Add ▸ Curve and Text,
# run the way the iPad runs them: Blender in background mode, factory
# settings, no 3D View area in the context.
#
# What Blender runs is what the Swift sends — the menu rows through
# BpyBridge.run itself, the adjustable operators as `perform` sends them — and
# after each the app's own _blenderkit_sync.py pushes the scene, which the
# Swift the device runs then builds and shows: hidden objects still listed with
# their eye closed, hidden faces out of edit mode, separated objects on screen,
# the modifier Auto Smooth adds in the Modifiers panel, curves and text drawn.
#
# Shade Auto Smooth is run again in a Blender without its Essentials asset
# library, as the device's bpy is (noassets.py).
#
# Skipped, not failed, when Blender is not installed.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
BUILD="${TMPDIR:-/tmp}/blenderlocal-objectmenu-blender"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/dump" Sources/BlenderLocalBridge/*.swift tests/objectmenu/blender/main.swift
"$BUILD/dump" > "$BUILD/calls.txt"
"$BLENDER" -b --factory-startup --python-exit-code 1 \
  --python tests/objectmenu/blender/verify.py -- "$BUILD/calls.txt" "$BUILD/passes.json"
"$BUILD/dump" "$BUILD/passes.json"

# The device's bpy has no Essentials asset library (its datafiles are
# colormanagement, fonts, icons and locale), which Shade Auto Smooth loads its
# node group from. Desktop Blender has one, so the run above cannot show what
# the device does. An APFS clone of the app with datafiles/assets removed can:
# a clone costs no disk and under a second, and is made again when Blender is.
echo
CLONE="$BUILD/BlenderNoAssets.app"
# Made fresh every run: an APFS clone costs seconds, and a kept one does not
# stay whole. Its files carry Blender's own dates, so macOS's clean-up of the
# temporary folder removes them piecemeal — after a day one had lost 814 of
# its 3,566 standard-library files, encodings/__init__.py among them, and its
# Python could not start ("no codec search functions registered").
rm -rf "$CLONE"
if cp -c -R "$(dirname "$(dirname "$(dirname "$BLENDER")")")" "$CLONE" 2>/dev/null; then
  rm -rf "$CLONE"/Contents/Resources/*/datafiles/assets
else
  rm -rf "$CLONE"
fi
if [ -x "$CLONE/Contents/MacOS/Blender" ]; then
  "$CLONE/Contents/MacOS/Blender" -b --factory-startup --python-exit-code 1 \
    --python tests/objectmenu/blender/noassets.py -- "$BUILD/calls.txt"
else
  echo "  SKIP  Blender without its Essentials library: no APFS clone (cp -c failed)"
fi
