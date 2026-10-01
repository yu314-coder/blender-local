#!/bin/bash
# The Swift half of undo with the real module: the history state the Python
# reports, the log line, and when the crash-recovery file is written.
# The Blender half is scripts/run-undo-blender-check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/blenderlocal-undo-tests.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
swiftc -O -o "$BUILD/run" \
  Sources/BlenderLocalBridge/*.swift \
  tests/undo/main.swift
"$BUILD/run"
