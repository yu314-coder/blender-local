#!/bin/bash
# Operators that must not run as they are called (tests/unsafe/blender/verify.py):
# `_blenderkit_context.UNSAFE_OPERATORS`, the one table a script line, Run,
# the console and the operator search all read. Every entry is refused, or
# given what it needs, by every route — the main thread and the script
# thread, the borrowed 3D View, an early lookup, `_bpy.ops.create_function`,
# a reload of `bpy.ops`, a script's own macro, the search, the module spelled
# in any case (`bpy.ops.UV.stitch`), a load's handlers — and without the
# guard the same calls take a Blender of their own down (Stitch, as a call
# and as a macro's step, a brush pick in a file opened in Vertex Paint or
# Sculpt Mode, Mask Fill with no undo stack, a macro's Loop Cut, load or
# BLOCKING undo, a Texture Paint brush outside a paint mode, Mask Fill or a
# second load in a load_post handler) or never return (Edge Ring Select,
# killed at 20 s). Those controls crash desktop Blender on
# purpose: each writes its backtrace into the work directory, which the check
# reads for the frame, and macOS keeps a Blender-*.ips in
# ~/Library/Logs/DiagnosticReports.
#
# Every Blender gets a home, resources and temporary folder of its own under
# the work directory, so nothing reaches this Mac's Blender settings. Nothing
# here opens a window, a browser or another app. About a minute (one of the
# controls runs with MallocScribble=1, so a read of freed memory fails every
# time instead of now and then). Skipped, not
# failed, when Blender is not installed.
set -uo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/blenderlocal-unsafe.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home/res" "$WORK/tmp"
# From the work directory, not the repo: what Blender writes into its working
# folder stays out of the tree (its children start where it is).
ROOT="$(pwd)"
cd "$WORK"
HOME="$WORK/home" BLENDER_USER_RESOURCES="$WORK/home/res" TMPDIR="$WORK/tmp" \
  "$BLENDER" -b --factory-startup --python-exit-code 1 --python "$ROOT/tests/unsafe/blender/verify.py" 2>&1 \
  | grep -E "^  (PASS|FAIL)|^[A-Z][a-z].*$|^ALL PASS|FAILED$" | grep -vE '^(Blender [0-9]|Read prefs|Writing:|Warning|Info)'
status=${PIPESTATUS[0]}
exit "$status"
