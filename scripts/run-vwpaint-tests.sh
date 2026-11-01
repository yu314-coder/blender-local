#!/bin/bash
# Weight Paint and Vertex Paint, the Swift half: the Python the header and the
# stroke send, the names they carry (Blender's), the state Blender answers
# with, and the Cycles warning's strings. Pure strings and decoding, so it runs
# on the Mac; scripts/run-vwpaint-blender-check.sh puts the same Python
# through Blender.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-vwpaint-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" Sources/BlenderLocalBridge/*.swift tests/vwpaint/main.swift
exec "$BUILD/run"
