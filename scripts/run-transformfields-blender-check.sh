#!/bin/bash
# The Transform fields (Properties ▸ Object and the N panel's Item tab), run
# the way the iPad runs them: Blender in background mode, factory settings, an
# undo stack and an initialised GPU as the app has them, the app's own
# `_blenderkit_sync.push_local` sending what the fields show, and the Swift the
# device runs showing it, previewing an edit and writing it.
#
# The scene is the one the review measured: a child whose parent moved and
# turned after Object ▸ Parent, which the fields showed at its world position
# while writing its local one. Beside it a quaternion, an axis angle, deltas in
# a ZXY Euler and a mirrored scale under a turned, scaled holder.
#
# Nothing here opens a window, a browser or another app, and Blender's own
# settings are not read or written (--factory-startup, and a HOME of its own).
# Skipped, not failed, when Blender is not installed.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/blenderlocal-transformfields-blender.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home"
swiftc -O -o "$WORK/dump" Sources/BlenderLocalBridge/*.swift tests/transformfields/blender/main.swift
"$WORK/dump" > "$WORK/calls.txt"
echo "  $(grep -c '^###' "$WORK/calls.txt") strings from the Swift"
HOME="$WORK/home" BLENDER_USER_RESOURCES="$WORK/home/res" \
  "$BLENDER" -b --factory-startup --python-exit-code 1 \
  --python tests/transformfields/blender/verify.py -- "$WORK/calls.txt" "$WORK/passes.json"
"$WORK/dump" "$WORK/passes.json"
