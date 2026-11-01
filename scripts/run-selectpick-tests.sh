#!/bin/bash
# Blender's pick selections (Loop Select, Edge Ring Select, Pick Shortest
# Path, Select Linked) and the Select menu's new rows, the Swift half: the
# keys, the element a hit names in Blender's numbering, the active element a
# loop makes, the calls with Blender's redo panels, the selection order a tap
# leaves, the push writes and the mirror reads, and the rows. Pure arithmetic
# and strings, so it runs on the Mac. What Blender makes of the calls is
# scripts/run-selectpick-blender-check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-selectpick-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" \
  Sources/BlenderLocalBridge/*.swift \
  tests/selectpick/main.swift
exec "$BUILD/run"
