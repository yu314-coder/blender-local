#!/bin/bash
# The Swift half of Sculpt Mode with Blender's brushes: the Python each control
# sends, Blender's answers read back, when a stroke's points go and a brush
# Size's field. The Blender half is scripts/run-sculpt-blender-check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/blenderlocal-sculpt-tests.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
swiftc -O -o "$BUILD/run" \
  Sources/BlenderLocalBridge/*.swift \
  tests/sculpt/main.swift
"$BUILD/run"
