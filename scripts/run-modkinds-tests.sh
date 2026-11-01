#!/bin/bash
# Round 4, group 8 on the Swift side: Blender's whole Add Modifier menu by
# object type, the eleven declared modifier rows (the record read back, what
# each setting and button sends), a text object's settings and Body Text, and
# image empties' record, Blender's rules for drawing the picture and the
# passes. Pure strings and models, so it runs on the Mac without a simulator.
# What Blender makes of it is scripts/run-modkinds-blender-check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-modkinds-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" \
  Sources/BlenderLocalBridge/*.swift \
  tests/modkinds/pictures.swift tests/modkinds/main.swift
exec "$BUILD/run"
