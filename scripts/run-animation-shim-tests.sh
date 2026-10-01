#!/bin/bash
# The simulator's animation — the shim's scene settings, I, Alt I and auto
# keying — run on the Mac against a model of the Swift the shim calls. The
# simulator is how the app is photographed, and it is not booted to check this.
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
PYTHONDONTWRITEBYTECODE=1 exec "$PYTHON" -B tests/animation/shim.py
