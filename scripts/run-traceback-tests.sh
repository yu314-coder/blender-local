#!/bin/bash
# Reading a line number out of a Python traceback is pure string work, so it
# runs on the Mac. Getting it wrong points the editor at the wrong line, which
# is worse than pointing at none.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-traceback-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" Sources/BlenderLocalBridge/*.swift tests/traceback/main.swift
exec "$BUILD/run"
