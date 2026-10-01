#!/bin/bash
# Bracket matching is pure text work, so it runs on the Mac. Getting it wrong
# boxes two characters that have nothing to do with each other, which is worse
# than not boxing anything.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-bracket-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" Sources/BlenderLocalBridge/*.swift tests/brackets/main.swift
exec "$BUILD/run"
