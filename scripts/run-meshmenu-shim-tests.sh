#!/bin/bash
# The simulator's stand-in for Blender, given every call the Mesh menu's
# round-4 rows send (the blocks scripts/run-meshmenu-blender-check.sh puts
# through desktop Blender): each does what Blender does or refuses in words
# (tests/meshmenu/shim.py).
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-meshmenu-shim"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/dump" Sources/BlenderLocalBridge/*.swift tests/meshmenu/blender/main.swift
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
PYTHONDONTWRITEBYTECODE=1 exec "$PYTHON" -B tests/meshmenu/shim.py "$BUILD/calls.txt"
