#!/bin/bash
# The Cursor tool's, the Measure tool's and Edit Mode's overlays' Swift half
# (CursorTool.swift, Ruler.swift, EditMeasure.swift, BlenderUnits.swift): the
# records, the calls a tap and a drag make, the hits on the mirror (a mirrored
# object's normal, Surface Project's margin), the ruler's picks and points, the
# overlay's labels and text, each with a control where it can fail. Pure
# arithmetic and strings, so it runs on the Mac. What Blender makes of the
# calls and whether the strings are Blender's is
# scripts/run-measure-blender-check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-measure-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" \
  Sources/BlenderLocalBridge/*.swift \
  tests/measure/main.swift
exec "$BUILD/run"
