#!/bin/bash
# The Mesh menu's rows round 4 (group 6) added, the Swift half
# (LastOperator.Mesh, MeshMenuTools.swift): Blender's names, groups and order,
# the calls and their refusals, the panels' hidden rows, a macro's vector, the
# pointer the 3D cursor stands in for, and the rows that cannot run. Pure
# strings, so it runs on the Mac. What Blender makes of the calls is
# scripts/run-meshmenu-blender-check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-meshmenu-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" \
  Sources/BlenderLocalBridge/*.swift \
  tests/meshmenu/main.swift
exec "$BUILD/run"
