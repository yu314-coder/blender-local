#!/bin/bash
# The simulator's snapping, pivot and proportional editing — the shim's
# bpy.ops.transform and _blenderkit_tools — run on the Mac against a model of
# the Swift the shim calls. The Swift itself is scripts/run-tools-tests.sh's.
set -euo pipefail
cd "$(dirname "$0")/.."
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
PYTHONDONTWRITEBYTECODE=1 exec "$PYTHON" -B tests/tools/shim.py
