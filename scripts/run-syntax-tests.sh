#!/bin/bash
# The Python syntax scanner is pure Swift over a string — no UIKit, by design —
# so it runs on the Mac without a simulator. Everything visual still needs a
# screenshot; this covers the part that silently mis-colours.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-syntax-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" \
  Sources/BlenderLocalBridge/PythonWords.swift \
  Sources/BlenderLocalUI/Editors/PythonSyntax.swift tests/syntax/main.swift
exec "$BUILD/run"
