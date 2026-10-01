#!/bin/bash
# Texture Paint's Python, run the way the iPad runs it: Blender in background
# mode, factory settings, no 3D View area.
#
# What is checked is what the Swift sends and assumes, printed by
# tests/texpaint/blender/main.swift: entering Texture Paint on a cube and on a
# mesh with no UVs or material; the image Blender would paint, also after a
# reload has emptied its slot cache; the UVs, slots and pixels the mirror hands
# the viewport, and when it does not; a stroke the engine painted written into
# Blender and packed, surviving a checkpoint, an undo and a redo; the brush
# settings and falloff against Blender's own essentials brushes.
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
WORK="$(mktemp -d "${TMPDIR:-/tmp}/blenderlocal-texpaint-blender.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
swiftc -O -o "$WORK/dump" Sources/BlenderLocalBridge/*.swift tests/texpaint/blender/main.swift
"$WORK/dump" > "$WORK/calls.txt"
"$BLENDER" -b --factory-startup --python-exit-code 1 \
  --python tests/texpaint/blender/verify.py -- "$WORK/calls.txt" "$WORK"
