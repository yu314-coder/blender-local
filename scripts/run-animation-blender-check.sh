#!/bin/bash
# Animation, run the way the iPad runs it: Blender in background mode, factory
# settings, no 3D View area.
#
# What it checks is what the Swift actually sends — the dump prints it, through
# TimelineDriver and BpyBridge.run — and, where Blender has an operator for what
# the app does headless, what that operator does: Insert Keyframe, Delete
# Keyframe and auto keying are each run both ways and held against each other.
# Also: the timeline's mirror of range, rate, settings and keys, including keys
# on object data; a frame change handing over only what moved or deformed, and
# how long it takes; Blender's frame-range rules; and Blender's own keys and
# keyframe jumps replayed through the Swift that draws the timeline.
#
# Blender 5.2.1 must be installed; skipped, not failed, when it is not. Builds
# and writes only inside a private temporary directory, because other checks
# run at the same time.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/blenderlocal-animation-blender.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
swiftc -O -o "$BUILD/check" \
  Sources/BlenderLocalBridge/*.swift \
  Sources/BlenderLocalUI/Viewport/ViewportCamera.swift \
  Sources/BlenderLocalUI/Viewport/ViewportOptions.swift \
  Sources/BlenderLocalUI/Viewport/TransformGizmo.swift \
  Sources/BlenderLocalUI/Viewport/TransformGizmoGeometry.swift \
  tests/gizmo/stub.swift \
  tests/animation/blender/main.swift
"$BUILD/check" dump > "$BUILD/calls.txt"
echo "  $(grep -c '^###' "$BUILD/calls.txt") strings from the Swift, put through Blender $("$BLENDER" --version | head -1 | cut -d' ' -f2)"
status=0
"$BLENDER" -b --factory-startup --python tests/animation/blender/verify.py -- \
  "$BUILD/calls.txt" "$BUILD/mirror.json" || status=1
"$BUILD/check" replay "$BUILD/mirror.json" || status=1
# A user's frame handler that deletes objects, each in a Blender of its own:
# what it guards against killed Blender (exit 139), which would have taken the
# rest of verify.py with it. Each variant reuses the freed memory differently.
echo
echo "a frame handler deletes keyed objects, and the app changes the frame"
mkdir -p "$BUILD/home"
for variant in geometry cameras meshes; do
  code=0
  HOME="$BUILD/home" BLENDER_USER_RESOURCES="$BUILD/home/res" \
    "$BLENDER" -b --factory-startup --python tests/animation/blender/handler_removes.py -- \
    Resources/python/site/_blenderkit_anim.py "$variant" > "$BUILD/handler-$variant.txt" 2>&1 || code=$?
  grep -E '^  (PASS|FAIL|ALL|[0-9]+ FAILED|\()' "$BUILD/handler-$variant.txt" || true
  if [ "$code" -ne 0 ]; then
    status=1
    grep -q 'ALL PASS\|FAILED' "$BUILD/handler-$variant.txt" \
      || echo "  FAIL  Blender died with exit $code ($variant): the frame path read freed memory"
  fi
done
exit $status
