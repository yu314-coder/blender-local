#!/bin/bash
# Loop Cut and the Knife's Swift half (CutTools.swift): which of Blender's
# edges a drawn edge is, the ring's preview from Blender's answer, the calls
# the commit sends, the knife's path and the refusals. Pure arithmetic and
# strings, so it runs on the Mac. What Blender makes of the calls, and whether
# the preview is the cut Blender makes, is scripts/run-cuttools-blender-check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-cuttools-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" \
  Sources/BlenderLocalBridge/*.swift \
  tests/cuttools/main.swift
exec "$BUILD/run"
