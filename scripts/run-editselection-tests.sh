#!/bin/bash
# What Blender reports as selected while editing, turned into what the
# viewport draws, and the viewport's selection turned back into what Blender
# is told. Index work over plain arrays, so it runs on the Mac. Getting it
# wrong makes a Bevel act on faces nobody can see selected.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-editselection-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" Sources/BlenderLocalBridge/*.swift tests/editselection/main.swift
exec "$BUILD/run"
