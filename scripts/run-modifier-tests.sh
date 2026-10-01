#!/bin/bash
# The modifier panel: the Python each row sends to Blender, the mirror record
# Blender sends back, and the simulator's own mesh operations. Pure simd and
# strings, so it runs on the Mac without a simulator, a device or Metal.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-modifier-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" Sources/BlenderLocalBridge/*.swift tests/modifiers/main.swift
exec "$BUILD/run"
