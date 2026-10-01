#!/bin/bash
# Completion is pure over its inputs by design — it takes the operator paths
# rather than reaching for the catalogue — so its ranking, the part that
# decides whether the strip feels useful or noisy, runs on the Mac.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-completion-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" \
  Sources/BlenderLocalBridge/PythonCompletion.swift \
  Sources/BlenderLocalBridge/PythonWords.swift \
  Sources/BlenderLocalBridge/BracketMatch.swift \
  tests/completion/main.swift
exec "$BUILD/run"
