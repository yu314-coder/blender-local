#!/bin/bash
# The names the app shows, held to Blender 5.2.1's (docs/blender-names.md).
#
# Two halves that need no Blender: every string literal the app ships is
# scanned for the names it used to show instead of Blender's
# (tests/names/scan.py, which first proves on snippets that it can fail), and
# every name the app builds from its tables — printed by tests/names/main.swift —
# is held to Blender's menus and toolbar as 5.2.1 draws them
# (tests/names/verify.py, against tests/names/reference). What only Blender
# can say is scripts/run-names-blender-check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-names-tests"
mkdir -p "$BUILD"
python3 tests/names/scan.py
swiftc -O -o "$BUILD/dump" Sources/BlenderLocalBridge/*.swift tests/names/main.swift
"$BUILD/dump" > "$BUILD/names.json"
exec python3 tests/names/verify.py "$BUILD/names.json"
