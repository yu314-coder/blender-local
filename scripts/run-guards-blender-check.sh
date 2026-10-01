#!/bin/bash
# The guards round 3's review found missing (tests/guards/blender/verify.py):
# loop cut with no 3D View, the vertex budget over the whole modifier stack and
# every way to reach it, symmetry's coordinates under a shape key, and
# Duplicate in Edit Mode.
#
# Blender gets a home of its own under TMPDIR, as the operator sweep's does:
# nothing it runs writes into this Mac's own Blender settings. The loop-cut
# negative control is a second Blender, expected to crash.
#
# Skipped, not failed, when Blender is not installed.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
home="${TMPDIR:-/tmp}/blenderlocal-guards-home"
mkdir -p "$home"
set +e
HOME="$home" BLENDER_USER_RESOURCES="$home/res" \
  "$BLENDER" -b --factory-startup --python-exit-code 1 --python tests/guards/blender/verify.py 2>&1 \
  | grep -E "^  (PASS|FAIL)|^[A-Z][a-z].*$|^ALL PASS|FAILED$" | grep -vE '^(Blender [0-9]|Read prefs|Writing:)'
status=${PIPESTATUS[0]}
set -e
exit "$status"
