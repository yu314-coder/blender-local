#!/bin/bash
# The console's line editor draws with escape sequences and decides when a
# statement is complete, and neither needs a terminal to do it. So both run on
# the Mac, against a screen made of strings that wraps the way a terminal does.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-terminal-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" \
  Sources/BlenderLocalBridge/*.swift \
  Sources/BlenderLocalUI/Terminal/ConsoleLineEditor.swift \
  Sources/BlenderLocalUI/Terminal/ConsoleLineEditor+Editing.swift \
  Sources/BlenderLocalUI/Terminal/ConsoleLineEditor+Keys.swift \
  Sources/BlenderLocalUI/Terminal/ConsoleTranscript.swift \
  Sources/BlenderLocalUI/Terminal/ConsoleLineEditor+Running.swift \
  Sources/BlenderLocalUI/Terminal/ConsoleRawStream.swift \
  tests/terminal/main.swift
exec "$BUILD/run"
