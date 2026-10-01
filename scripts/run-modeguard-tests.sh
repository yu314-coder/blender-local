#!/bin/bash
# Which Blender mode a bare operator needs is string work, and whether the bridge
# applies it is plain Swift, so both run on the Mac. Getting either wrong strands
# Blender in a mode where half the interface fails its poll — and one add crashes
# the process.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-modeguard-tests"
mkdir -p "$BUILD"
# The bridge checks need the bridge, and the bridge needs the rest of the module.
swiftc -O -o "$BUILD/run" Sources/BlenderLocalBridge/*.swift tests/modeguard/main.swift
exec "$BUILD/run"
