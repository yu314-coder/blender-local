#!/bin/bash
# The redo panel writes Python that Blender has to accept: the argument names
# and their types are not negotiable, and a wrong one is a TypeError in the
# console rather than a shape on the screen. The arguments here were read out of
# Blender 5.2.1's own RNA, so this is a comparison against Blender, not against
# what I remembered of it.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-redo-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" \
  Sources/BlenderLocalBridge/*.swift \
  tests/redo/main.swift
exec "$BUILD/run"
