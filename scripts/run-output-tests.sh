#!/bin/bash
# Render Animation and the Properties editor's Render, Output and World tabs,
# on the Mac: the requests' Python, the settings Blender reports read back,
# Blender's Frame Rate menu, the frame-in-hand and outcome files, and the
# wiring (keys, menus, tabs) by source. What Blender makes of the strings is
# scripts/run-renderanim-blender-check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-output-tests"
mkdir -p "$BUILD"
swiftc -Onone -o "$BUILD/run" Sources/BlenderLocalBridge/*.swift tests/output/main.swift
exec "$BUILD/run" "$(pwd)"
