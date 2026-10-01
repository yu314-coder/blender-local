#!/bin/bash
# Object ▸ Duplicate Linked, Join, Parent, Clear Parent and Convert, the Mesh
# menu's new rows and Shear, on the Swift side: the Python each row sends, the
# redo panel's fields, which rows are offered, the Outliner's parent tree and
# the selection a redo-panel re-run hands back. Pure strings and models, so it
# runs on the Mac without a simulator. What Blender makes of it is
# scripts/run-objectops-blender-check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-objectops-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" \
  Sources/BlenderLocalBridge/*.swift \
  tests/objectops/main.swift
exec "$BUILD/run"
