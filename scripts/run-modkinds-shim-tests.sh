#!/bin/bash
# Round 4, group 8's declared modifier rows in the simulator's stand-in: every
# line the rows send for them run through the shim's bpy against a model of
# the Swift it calls, whose rules are read out of ModifierFields.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-modkinds-shim"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/dump" Sources/BlenderLocalBridge/*.swift tests/modkinds/pictures.swift tests/modkinds/blender/main.swift
"$BUILD/dump" calls > "$BUILD/calls.txt"
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
PYTHONDONTWRITEBYTECODE=1 exec "$PYTHON" -B tests/modkinds/shim.py "$BUILD/calls.txt"
