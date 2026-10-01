#!/bin/bash
# Image to 3D Model's geometry — outline, inflation, faces, UVs and the files
# Blender reads — is arithmetic, so it runs on the Mac. Blender's side is
# run-image3d-blender-check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-image3d-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" Sources/BlenderLocalBridge/*.swift tests/image3d/main.swift
exec "$BUILD/run"
