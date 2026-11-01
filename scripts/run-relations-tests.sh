#!/bin/bash
# Round 4, group 7 on the Swift side: Blender's collections in the Outliner
# (the record the mirror reads, the tree built from it), Local View's record
# and framing, the Object Constraints tab's record and commands, and the
# Object menu's Mirror, Link/Transfer Data, Make Single User, Copy Modifiers,
# Randomize Transform and Align Objects rows. Pure strings and models, so it
# runs on the Mac without a simulator. What Blender makes of it is
# scripts/run-relations-blender-check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-relations-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" \
  Sources/BlenderLocalBridge/*.swift \
  tests/relations/main.swift
exec "$BUILD/run"
