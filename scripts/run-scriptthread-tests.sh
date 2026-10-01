#!/bin/bash
# Which thread a script runs on is decided from its text, so it is checked on
# the Mac. The Blender side of the same bug is run-context-blender-check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-scriptthread-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" Sources/BlenderLocalBridge/*.swift tests/scriptthread/main.swift
exec "$BUILD/run"
