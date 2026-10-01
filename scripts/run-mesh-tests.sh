#!/bin/bash
# The mesh operations behind the per-mode header menus are pure Swift over
# simd, so they run on the Mac without a simulator, a device or Metal.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-mesh-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" Sources/BlenderLocalBridge/*.swift tests/meshops/main.swift
exec "$BUILD/run"
