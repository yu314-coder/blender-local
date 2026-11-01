#!/bin/bash
# Every desktop Blender a check script starts gets a HOME and
# BLENDER_USER_RESOURCES of its own, so no check can write this Mac's own
# Blender settings or its ~/.thumbnails. Reads every
# scripts/run-*-blender-check.sh and fails on a Blender started without them;
# its first checks show it catches one. No Blender is run.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 tests/sandbox/check.py scripts/run-*-blender-check.sh
