#!/bin/bash
# The vertex budget held to Blender (round 4's fix round): its model has
# every modifier type; every int, float, enum and bool setting of every Add
# Modifier row on a mesh, a curve, a text and a surface — and of the curve's,
# surface's and text's data and first spline — is stepped up and down on a
# small fixture and the budget's count held to Blender's evaluated count (a
# setting that grows Blender's mesh while the count does not follow fails);
# round 4's bypasses through the rows' own lines; ordinary edits; non-finite
# geometry. Each part has a control that has to fail. Part 11
# (tests/budget/blender/frames.py): a frame change priced from its plan, in
# proportion to what it changes, and a legal Boolean priced from at most
# two of Blender's evaluations, each with its timing bound and its control.
# Part 13 (tests/budget/blender/review13.py): the review of part 11's work
# answered — a Boolean's faces in one plane, Self Intersection and moved
# collection operands; the frame plan after a post handler or a refused
# line; drivers of the frame, through another path, or reading each other;
# NLA blending, Time Stretching, node groups; rigs and clamped keys — each
# beside the review's own count or the old code put back. Part 12i
# (tests/budget/blender/interface3.py, run at the end of part 12, or alone
# with BUDGET_PARTS=12i): fix round 3's — Time Stretching set as a value, an
# F-curve modifier, nested instances realized and a curve object's curves in
# Geometry Nodes, Affect Only on a move, Fast's Overlap Threshold, Self
# Intersection's own faces in one plane, a collection's operands in one BVH
# (timed), drivers reading what the Data API row sets, legacy textures —
# each with the gap put back as its control. Part 12j
# (tests/budget/blender/interface4.py, after 12i, or alone with
# BUDGET_PARTS=12j): the review of 12i's work — a move in a bare orientation
# (every orientation swept), Duplicate and Add in Object Mode into a
# collection Geometry Nodes realizes, Single Property drivers reading
# matrix_world and Dimensions, a colour ramp's colours and stops, empties
# that instance a collection, Fast's own time, Self Intersection timed —
# each with the gap put back as its control. Part 12s
# (tests/budget/blender/script3.py, after part 12, or alone with
# BUDGET_PARTS=12s): fix round 3's script-only gaps — what a refusal leaves,
# a Background Scene and a Rigid Body World, hair curves, long custom-property
# arrays, a script's handlers and the gate's own handler taken out, a frame's
# probe, drivers reading each other, renders of other scenes, bakes and
# exports, an image's pixels, Line Art, a file a script loads — each with the
# gap put back as its control. Part 12t (tests/budget/blender/review3s.py,
# last, or alone with BUDGET_PARTS=12t): the review of 12s's work — a
# handler with no code of its own, a module a script makes, the base type's
# entry with both lists cleared and other ways round held at the mirror's
# pass, a handler that is also a getter, the app's own loads of files a
# script wrote (the Swift's strings among them) — each with the reviewed
# code put back as its control.
#
# `BUDGET_CONTROL=BEVEL scripts/run-budget-blender-check.sh` runs the sweep
# alone with that kind counted as making nothing (today's bypass put back):
# it has to report the Bevel's Segments.
#
# Blender in background mode, factory settings, a HOME of its own, its undo
# started through the app's `_blenderkit_undo` and its history in a private
# temporary directory. Nothing here opens a window, a browser or another app.
# Skipped, not failed, when Blender is not installed.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/blenderlocal-budget-blender.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Documents" "$WORK/home/res" "$WORK/tmp"
swiftc -O -o "$WORK/dump" Sources/BlenderLocalBridge/*.swift tests/budget/blender/main.swift
"$WORK/dump" > "$WORK/calls.txt"
echo "  $(grep -c '^###' "$WORK/calls.txt") strings from the Swift, put through Blender $("$BLENDER" --version | head -1 | cut -d' ' -f2)"
# Run from the temporary folder, not the repo: Mantaflow writes its 25 MB
# wavelet noise tile into Blender's working folder when it is missing
# (noisefield.cpp, `fopen(TILENAME, "wb")`), and part 2 steps Fluid domains.
ROOT="$(pwd)"
cd "$WORK"
HOME="$WORK/home" BLENDER_USER_RESOURCES="$WORK/home/res" TMPDIR="$WORK/tmp" \
  "$BLENDER" -b --factory-startup --python-exit-code 1 \
  --python "$ROOT/tests/budget/blender/verify.py" -- "$WORK/calls.txt" "$WORK" &
blender=$!
# A bypass a sweep finds is Blender building past the budget: held to what
# this Mac can spare, so finding one costs a failed check, not the Mac.
# Killed past 12 GB resident, and the check fails.
( while kill -0 "$blender" 2>/dev/null; do
    rss=$(ps -o rss= -p "$blender" 2>/dev/null | tr -d ' ')
    if [ -n "$rss" ] && [ "$rss" -gt 12000000 ]; then
      echo "  FAIL  Blender passed 12 GB resident (${rss} KB) and was stopped: something was built past the budget"
      kill -9 "$blender"
    fi
    sleep 1
  done ) &
watchdog=$!
set +e
wait "$blender"
status=$?
set -e
kill "$watchdog" 2>/dev/null || true
# Reaped here, quietly: otherwise bash reports the killed watchdog during
# part 10 and prints its source, "FAIL" line and all, into the log (the first
# full run with part 10 did, a FAIL that was not one).
wait "$watchdog" 2>/dev/null || true
# Part 10: every operator the Operator Search lists, as the search runs it,
# on a scene of traps where any growth passes a lowered budget — with the
# gate, nothing may grow Blender past it; with the gate off and nothing
# priced (the control), the sweep has to find what does
# (tests/budget/blender/opdrive.py: one Blender per state, a HOME and a
# temporary folder of its own each, restarted after a crash).
if [ -z "${BUDGET_PARTS:-}" ] || [[ ",${BUDGET_PARTS}," == *",10,"* ]]; then
  echo
  echo "10. every operator the search lists, on traps where any growth passes the budget"
  set +e
  (cd "$ROOT" && python3 tests/budget/blender/opdrive.py)
  sweep=$?
  (cd "$ROOT" && python3 tests/budget/blender/opdrive.py control)
  control=$?
  set -e
  [ "$sweep" -eq 0 ] && [ "$control" -eq 0 ] || status=1
fi
exit $status
