#!/bin/bash
# Typed values in Edit Mode, transform orientations, the gizmo's redo panel
# and typed Dimensions, held to Blender itself (tests/transformops/blender):
#
#   1. orient.py — the app's port of Blender's orientations
#      (`_blenderkit_orient`) against the matrix Blender works out itself, case
#      by case, in Object and Edit Mode; Active Element against Blender's 3D
#      View; a negative control that must disagree.
#   2. write_fixtures.py, then main.swift dump — Blender's scenes handed to the
#      Swift as the mirror hands them, and every gizmo drag in every
#      orientation previewed by the real session, with the call its release
#      performs; then the redo panel's changes.
#   3. run_calls.py — each call run in Blender on its fixture, Blender's result
#      held to the preview; a negative control (a View drag sent without its
#      matrix) that must land elsewhere.
#   4. item.py — the Sidebar's Item tab: Median and Vertex, Global and Local,
#      the weights, one undo step each, Dimensions (and their negative
#      control).
#   5. main.swift parse — the lines Blender printed, read back as the app
#      reads them.
#
# Each Blender gets a home of its own under TMPDIR, as the other checks' do:
# nothing it runs writes into this Mac's own Blender settings, and nothing
# opens a window, a browser or another program.
#
# Skipped, not failed, when Blender is not installed.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
BUILD="${TMPDIR:-/tmp}/blenderlocal-transformops-blender"
rm -rf "$BUILD"
mkdir -p "$BUILD/home"
blender() {
  BK_WORK="$BUILD/work-$1" HOME="$BUILD/home" BLENDER_USER_RESOURCES="$BUILD/home/res" \
    BK_REPORTS="$BUILD/reports.txt" BK_STATES="$BUILD/states.txt" \
    "$BLENDER" -b --factory-startup --python-exit-code 1 --python "tests/transformops/blender/$1.py" -- "${@:2}" 2>&1 \
    | grep -E "^  (PASS|FAIL|TIE)|^  [0-9]|^[0-9]+ (PASS|orient)|^wrote|Error|Traceback" \
    | grep -vE '^(Blender [0-9]|Read prefs|Writing:)'
  return "${PIPESTATUS[0]}"
}
swiftc -O -o "$BUILD/main" \
  Sources/BlenderLocalBridge/*.swift \
  Sources/BlenderLocalUI/Viewport/ViewportCamera.swift \
  Sources/BlenderLocalUI/Viewport/ViewportOptions.swift \
  Sources/BlenderLocalUI/Viewport/TransformGizmo.swift \
  Sources/BlenderLocalUI/Viewport/TransformGizmoGeometry.swift \
  tests/gizmo/stub.swift \
  tests/transformops/blender/main.swift
status=0
echo "Blender's orientations against the port"
blender orient || status=1
echo
echo "The drags, previewed in Swift on Blender's fixtures"
blender write_fixtures "$BUILD/fixtures.json" || status=1
"$BUILD/main" dump "$BUILD/fixtures.json" "$BUILD/cases.json" || status=1
echo
echo "Each release's call run in Blender, against its preview"
blender run_calls "$BUILD/cases.json" || status=1
echo
echo "The Sidebar's Item tab"
blender item || status=1
echo
echo "What Blender printed, read as the app reads it"
"$BUILD/main" parse "$BUILD/reports.txt" "$BUILD/states.txt" | grep -vE "^  PASS" || true
"$BUILD/main" parse "$BUILD/reports.txt" "$BUILD/states.txt" > /dev/null || status=1
exit "$status"
