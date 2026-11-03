#!/bin/bash
# The Data API browser's value formatting (DataAPIFormat.swift): tests/dataapi.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-dataapi-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" \
  Sources/BlenderLocalBridge/*.swift \
  tests/dataapi/main.swift
exec "$BUILD/run"
