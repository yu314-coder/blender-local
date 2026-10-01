#!/bin/bash
# Box, Circle and Lasso select's screen-space pass — what a region covers, what
# the surface hides without X-Ray, what a gesture does to the selection — and
# the Select menu's Python. Pure geometry and strings, so it runs on the Mac.
# What Blender makes of it is scripts/run-regionselect-blender-check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-regionselect-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" \
  Sources/BlenderLocalBridge/*.swift \
  Sources/BlenderLocalUI/Viewport/ViewportCamera.swift \
  tests/regionselect/main.swift
exec "$BUILD/run"
