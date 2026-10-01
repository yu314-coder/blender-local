#!/bin/bash
# The Transform fields (Properties ▸ Object, the N panel's Item tab) on the
# Swift side: the channels the mirror sends and where they go, what the fields
# show without them, the Python one field's edit sends, and the viewport's
# preview of it. Pure simd and strings. What Blender makes of it is
# scripts/run-transformfields-blender-check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-transformfields-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" Sources/BlenderLocalBridge/*.swift tests/transformfields/main.swift
exec "$BUILD/run"
