#!/bin/bash
# Sculpt Mode with Blender's own brushes, run the way the app runs it: Blender
# in background mode, factory settings, the strings the Swift sends (printed by
# tests/sculpt/blender/main.swift) through the modules the app ships.
#
# The view the strokes are aimed through, the refusals, a Draw stroke streamed
# in chunks against the same stroke in one call, Grab past the silhouette, a
# Snake Hook cut into pieces, every Essentials brush with Undo and Redo, the
# brush settings read back, Dynamic Topology, Voxel Remesh, Multires, the Mask
# menu and Face Sets, what a chunk costs on 100k triangles, and a stroke after
# a file load has freed Blender's undo stack. See verify.py.
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
WORK="$(mktemp -d "${TMPDIR:-/tmp}/blenderlocal-sculpt-blender.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Documents" "$WORK/home/res"
swiftc -O -o "$WORK/dump" Sources/BlenderLocalBridge/*.swift \
  Sources/BlenderLocalUI/Viewport/ViewportCamera.swift tests/sculpt/blender/main.swift
"$WORK/dump" > "$WORK/calls.txt"
echo "  $(grep -c '^###' "$WORK/calls.txt") strings from the Swift, put through Blender $("$BLENDER" --version | head -1 | cut -d' ' -f2)"
HOME="$WORK/home" BLENDER_USER_RESOURCES="$WORK/home/res" "$BLENDER" -b --factory-startup \
  --python-exit-code 1 --python tests/sculpt/blender/verify.py -- "$WORK/calls.txt" "$WORK" 2>&1 \
  | grep -vE '^(Blender [0-9]|Read prefs|$)'
exit "${PIPESTATUS[0]}"
