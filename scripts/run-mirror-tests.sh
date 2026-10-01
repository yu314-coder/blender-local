#!/bin/bash
# The mirror's Swift half: what one pushed object becomes, a mesh with no faces
# carried by its edges, the merge of a pass into what is on screen, and a wire
# object picked by its lines. Pure simd and strings; no Metal, no Python.
# What Blender's own sync sends through it: scripts/run-mirror-blender-check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-mirror-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" Sources/BlenderLocalBridge/*.swift tests/mirror/main.swift
exec "$BUILD/run"
