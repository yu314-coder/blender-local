#!/bin/bash
# The Swift half of the Self-Test: the Python the app sends, the progress
# lines the sheet reads, the report's name, and the last report found again
# after a run that took the app down. The Blender half is
# scripts/run-selftest-blender-check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/blenderlocal-selftest-tests.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
swiftc -O -o "$BUILD/run" \
  Sources/BlenderLocalBridge/*.swift \
  tests/selftest/main.swift
"$BUILD/run"
