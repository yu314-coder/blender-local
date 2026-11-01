#!/bin/bash
# The Swift half of Test All Features that needs no interface: the rating and
# its thresholds, frame times, the report's lines read back, the report found
# again after a run that took the app down, and the inventory — every feature
# either run by a case of FeatureTestRunner's or listed with why it is not.
# The run itself is the app's: `-feature-test` in a DEBUG build, Preferences ▸
# Testing ▸ Test All Features in any.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/blenderlocal-featuretest-tests.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
swiftc -O -o "$BUILD/run" \
  Sources/BlenderLocalBridge/*.swift \
  tests/featuretest/main.swift
"$BUILD/run" "$PWD"
