#!/bin/bash
# The normals the 3D View shades a mesh with, the Swift half
# (SceneMirror.installShading, MeshData.shadingNormal and carryShading):
# Blender's face and corner normals installed per triangle corner, the
# fast path's unchanged meshes, a frame change's way onto the screen, and a
# drag's preview turning a flat face's normal with it. Pure simd; no Metal, no
# Python. What Blender's own sync sends through it:
# scripts/run-shading-blender-check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-shading-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" Sources/BlenderLocalBridge/*.swift tests/shading/main.swift
exec "$BUILD/run"
