#!/bin/bash
# The half of the redo-panel tests that cannot lie.
#
# It builds the catalogue, prints every call it can emit, and runs those through
# desktop Blender — so what is checked is what the Swift actually produces, not
# a hand-written list of what it was supposed to produce. Blender is the only
# thing that can say whether an argument name is real, and a real scene is the
# only place an orphaned datablock or a bevel compounding on its own output
# shows up.
#
# Skipped, not failed, when Blender is not installed: this is a desktop check
# for an iPad app.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
BUILD="${TMPDIR:-/tmp}/blenderlocal-redo-blender"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/dump" \
  Sources/BlenderLocalBridge/*.swift \
  tests/redo/blender/main.swift
"$BUILD/dump" > "$BUILD/calls.txt"
echo "  $(grep -c '^###' "$BUILD/calls.txt") calls to put through Blender $("$BLENDER" --version | head -1 | cut -d' ' -f2)"
"$BLENDER" -b --factory-startup --python tests/redo/blender/verify.py -- "$BUILD/calls.txt"
# A second, fresh Blender: which thread starts the GPU module first is the
# point of this one, and the first run has already started it.
exec "$BLENDER" -b --factory-startup --python tests/redo/blender/gpu_order.py -- "$BUILD/calls.txt"
