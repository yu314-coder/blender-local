#!/bin/bash
# Properties ▸ Material, the Swift half: the state the tab reads, what each
# control sends, the slots the 3D View draws (looks, triangles by slot, the
# merge) and a drag's preview. Pure strings; no Metal, no Python. What
# Blender does with it: scripts/run-material-blender-check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-material-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" Sources/BlenderLocalBridge/*.swift tests/material/main.swift
exec "$BUILD/run" "$(pwd)"
