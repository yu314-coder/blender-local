#!/bin/bash
# The timeline's logic is plain Swift, so it runs on the Mac: the playback
# clock and its frame dropping, Blender's frame rules, the summary of keys and
# the jumps, the mirror's buffers, and what the driver sends through the bridge
# — against a runtime that records what would reach Blender. Builds in a
# private temporary directory, because other suites run at the same time.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/blenderlocal-animation-tests.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
swiftc -O -o "$BUILD/run" \
  Sources/BlenderLocalBridge/*.swift \
  tests/animation/main.swift
"$BUILD/run"
