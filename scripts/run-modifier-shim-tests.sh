#!/bin/bash
# The simulator's modifiers: every line the Modifiers panel's rows send, run
# through the shim's bpy against a model of the Swift it calls. The lines are
# the ones scripts/run-modifier-blender-check.sh puts through desktop Blender.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-modifier-shim"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/dump" Sources/BlenderLocalBridge/*.swift tests/modifiers/blender/main.swift
"$BUILD/dump" > "$BUILD/calls.txt"
PYTHON=""
for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
  if [ -x "$candidate" ]; then
    PYTHON="$candidate"
    break
  fi
done
if [ -z "$PYTHON" ]; then
  echo "No python3 found" >&2
  exit 1
fi
PYTHONDONTWRITEBYTECODE=1 exec "$PYTHON" -B tests/modifiers/shim.py "$BUILD/calls.txt"
