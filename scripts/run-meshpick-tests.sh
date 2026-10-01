#!/bin/bash
# What a tap in edit mode picks: a real cube, a real camera, and taps given as
# points on an iPad-sized 3D View. The tolerance used to be measured in clip
# space, which is a different number of points across than it is up, so most
# taps picked nothing — and picking nothing clears the selection.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-meshpick-tests"
mkdir -p "$BUILD"
UI="Sources/BlenderLocalUI/Viewport"
swiftc -O -o "$BUILD/run" Sources/BlenderLocalBridge/*.swift \
  "$UI/ViewportCamera.swift" "$UI/ViewportOptions.swift" \
  "$UI/TransformGizmo.swift" "$UI/TransformGizmoGeometry.swift" \
  tests/gizmo/stub.swift tests/meshpick/main.swift
exec "$BUILD/run"
