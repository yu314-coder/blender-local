#!/bin/bash
# What Blender has freed, read by the gate (fix round 3, October 29):
# tests/budget/blender/freed.py, one Blender per case, each under
# MallocScribble=1 and MallocGuardEdges=1 (freed memory overwritten, so a
# read of it crashes instead of finding what was there), several rounds each.
# Fix round 2's use-after-free (a 61 x 61 grid under a one-node Geometry
# Nodes group, Edit Mode, Extrude, leaving Edit Mode) and its variants: other
# modifiers and Edit Mode operators, Undo and Redo across the leave, the
# sculpt and paint modes, curves, lattices, metaballs, text, armatures, an
# image, a font and an action removed while Blender's copies point at them,
# the window's own scene removed. And the prices those paths hold: Bevel
# Weights written by a script line, a script's bmesh edit left in the same
# line, the other scene the window is given.
#
#   scripts/run-freed-blender-check.sh [rounds=N] [repeat=N] [cases=a,b]
#   BK_SITE=<another copy of Resources/python/site> scripts/run-freed-blender-check.sh
#
# The second is the negative control: pointed at 6d31b90's modules, 16 of the
# 26 cases fail, 13 of them crashing and 3 failing their price. Each Blender
# gets a HOME, BLENDER_USER_RESOURCES and TMPDIR of its own and runs from a
# temporary folder (freed_drive.py). Nothing here opens a window, a browser or
# another app. 20 to 30 seconds, four Blenders at a time (October 29, at a
# load average of 15 to 20). Skipped, not failed, when Blender is not
# installed.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
echo "What Blender has freed, read by the gate, under MallocScribble (one Blender per case)"
exec python3 tests/budget/blender/freed_drive.py "$@"
