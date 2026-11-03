#!/bin/bash
# The Data API browser's reader (_blenderkit_sync.inspect_data) against
# desktop Blender: tests/dataapi/blender/verify.py.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
home="${TMPDIR:-/tmp}/blenderlocal-dataapi-blender/home"
mkdir -p "$home"
exec env HOME="$home" BLENDER_USER_RESOURCES="$home/res" "$BLENDER" -b --factory-startup --python-exit-code 1 \
  --python tests/dataapi/blender/verify.py
