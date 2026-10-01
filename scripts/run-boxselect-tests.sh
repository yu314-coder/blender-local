#!/bin/bash
# Which objects a dragged rectangle covers is pure geometry, so it runs on the
# Mac. Getting it wrong selects the wrong things, which is worse than not
# selecting at all.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-boxselect-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" \
  Sources/BlenderLocalBridge/*.swift \
  Sources/BlenderLocalUI/Viewport/ViewportCamera.swift \
  tests/boxselect/main.swift
exec "$BUILD/run"
