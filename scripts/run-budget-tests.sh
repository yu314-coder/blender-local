#!/bin/bash
# The vertex budget's Swift half (round 4's fix round): every modifier row's
# edit, every Add Modifier row and the curve Data tab send the budget's one
# price in front of what they set, and no Swift string in Sources/ assigns a
# modifier's or a curve's setting bare (a source scan, with its allow-list).
# Pure strings, so it runs on the Mac without a simulator; what Blender makes
# of the Python is scripts/run-budget-blender-check.sh.
#
# Section 7 runs the gate itself (tests/budget/blender/smoke.py) in desktop
# Blender, sandboxed as every Blender check is (a HOME, BLENDER_USER_RESOURCES
# and TMPDIR of its own, started from a temporary folder): round 4's fix round
# 2 review found the source scans above passing with the gate's price taken
# out. `BK_SITE=<folder>` points it at a copy of Resources/python/site (the
# controls). Where desktop Blender is not installed, the section fails: the
# suite cannot vouch for the gate without it.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-budget-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" Sources/BlenderLocalBridge/*.swift tests/budget/main.swift
set +e
"$BUILD/run" "$(pwd)"
swift=$?
set -e
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo
  echo "7. the gate's behaviour, in desktop Blender"
  echo "  FAIL  desktop Blender is not installed at $BLENDER, so the gate's behaviour is not checked"
  exit 1
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/blenderlocal-budget-smoke.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home/res" "$WORK/tmp"
ROOT="$(pwd)"
set +e
(cd "$WORK" && HOME="$WORK/home" BLENDER_USER_RESOURCES="$WORK/home/res" TMPDIR="$WORK/tmp" \
  "$BLENDER" -b --factory-startup --python-exit-code 1 --python "$ROOT/tests/budget/blender/smoke.py" -- "$WORK" 2>&1 \
  | grep -E "^  (PASS|FAIL)|^7\.|ALL PASS|FAILED$")
smoke=${PIPESTATUS[0]}
set -e
[ "$swift" -eq 0 ] && [ "$smoke" -eq 0 ]
