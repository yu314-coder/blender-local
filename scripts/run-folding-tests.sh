#!/bin/bash
# Where a Python block ends is pure text work, so it runs on the Mac. Folding
# the wrong range hides code the reader did not ask to hide.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-folding-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" Sources/BlenderLocalBridge/*.swift tests/folding/main.swift
exec "$BUILD/run"
