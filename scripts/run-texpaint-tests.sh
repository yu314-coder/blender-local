#!/bin/bash
# Texture Paint's engine on the Mac: Blender's byte blending and falloff,
# projection painting through orthographic and perspective views, occlusion,
# normal falloff, seam bleed, symmetry, Blur/Smear/Average, pixels between
# Blender's floats and the viewport's bytes, and the simulator's stand-in with
# its undo. Plain Swift over plain values: no Metal, no simulator, no Blender.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/blenderlocal-texpaint-tests.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
swiftc -O -o "$BUILD/run" Sources/BlenderLocalBridge/*.swift tests/texpaint/main.swift
"$BUILD/run"
