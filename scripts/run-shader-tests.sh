#!/bin/bash
# The viewport's line shader, compiled from Shaders.metal and drawn on this
# Mac's GPU with the normals Blender sends — including the (0,0,0) it gives a
# wire vertex at the object's origin, which once made every edge touching it
# NaN and invisible. Skipped, not failed, without a Metal device.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/blenderlocal-shader-tests.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
swiftc -O -o "$BUILD/run" tests/shaders/main.swift
"$BUILD/run" "${1:-Sources/BlenderLocalUI/Viewport/Shaders.metal}"
