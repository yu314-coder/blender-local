#!/bin/bash
# The Self-Test (Resources/python/site/_blenderkit_selftest.py, opened in the
# app by seven taps on Preferences' Version row) run in desktop Blender 5.2.1
# with the app's context, as the app runs it: the Python `SelfTest.python`
# builds (dumped from the Swift by tests/selftest/blender/main.swift), on a
# scene of the user's own left in Edit Mode, under MallocScribble=1 and
# MallocGuardEdges=1. tests/selftest/blender/verify.py holds the run to its
# report (a header, one line per check, the summary), to every check's PASS,
# to the user's scene coming back as it was, and to the history Undo can
# reach afterwards; the Swift then reads every progress line the run printed,
# as the sheet does. A second run starts as the app does from a recovery file
# open in Vertex Paint; a third, with painted pixels not saved yet, has to
# refuse in one line before it saves or opens anything.
#
# The control: the same run on 6d31b90's modules (`git archive`), which has to
# crash Blender or report a FAIL — it crashes in the first check, the use-after
# free fix round 3 closed.
#
#   scripts/run-selftest-blender-check.sh
#   BK_SITE=<another copy of Resources/python/site> scripts/run-selftest-blender-check.sh
#
# Each Blender gets a HOME, BLENDER_USER_RESOURCES and TMPDIR of its own and
# runs from a temporary folder. Nothing here opens a window, a browser or
# another app. About a minute, most of it compiling the Swift. Skipped, not
# failed, when Blender is not installed.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
ROOT="$(pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/blenderlocal-selftest-blender.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
swiftc -O -o "$WORK/dump" Sources/BlenderLocalBridge/*.swift tests/selftest/blender/main.swift
"$WORK/dump" > "$WORK/request.py"
echo "  the app's request: $(wc -l < "$WORK/request.py" | tr -d ' ') lines, put through Blender $("$BLENDER" --version | head -1 | cut -d' ' -f2)"

# One run: a sandboxed Blender in a folder of its own, its log kept.
selftest() {
  local name="$1" site="$2" base="$WORK/$1"
  shift 2
  mkdir -p "$base/home/res" "$base/tmp"
  set +e
  (cd "$base" && HOME="$base/home" BLENDER_USER_RESOURCES="$base/home/res" TMPDIR="$base/tmp" \
     MallocScribble=1 MallocGuardEdges=1 BK_SITE="$site" \
     "$BLENDER" -b --factory-startup --python-exit-code 1 \
     --python "$ROOT/tests/selftest/blender/verify.py" -- "$base" "$WORK/request.py" "$@" \
     > "$base/log" 2>&1)
  local code=$?
  set -e
  return $code
}

SITE="${BK_SITE:-$ROOT/Resources/python/site}"
echo
echo "The Self-Test on the modules in $SITE, the user's scene in Edit Mode"
status=0
selftest tree "$SITE" edit=1 || status=$?
grep -E "^  (PASS|FAIL)  |^    \| |^The user's scene|^Self-Test check" "$WORK/tree/log" || true
if [ "$status" -ne 0 ]; then
  echo "  FAIL  the run exited $status"
  tail -25 "$WORK/tree/log"
fi
"$WORK/dump" parse "$WORK/tree/log" || status=1

echo
echo "Again, as the app launches with its recovery file in Vertex Paint (the history's probe waiting)"
code=0
selftest paint "$SITE" paint=1 || code=$?
grep -E "^  (PASS|FAIL)  |^The user's scene|^Self-Test check" "$WORK/paint/log" || true
if [ "$code" -ne 0 ]; then
  echo "  FAIL  the run exited $code"
  tail -15 "$WORK/paint/log"
  status=1
fi

echo
echo "Painted pixels not saved yet: the run refuses before it saves or opens anything"
code=0
selftest painted "$SITE" dirty=1 || code=$?
grep -E "^  (PASS|FAIL)  " "$WORK/painted/log" || true
if [ "$code" -ne 0 ]; then
  echo "  FAIL  the run exited $code"
  tail -15 "$WORK/painted/log"
  status=1
fi

echo
echo "Control: the same run on 6d31b90's modules, which has to crash Blender or report a FAIL"
if git cat-file -e 6d31b90 2>/dev/null; then
  mkdir -p "$WORK/old"
  git archive 6d31b90 Resources/python/site | tar -x -C "$WORK/old"
  code=0
  # Blender's crash here is the control holding (bash says "Segmentation fault").
  selftest control "$WORK/old/Resources/python/site" edit=1 2>/dev/null || code=$?
  report="$WORK/control/Documents/Self-Test/self-test-desktop.txt"
  running=$(grep -m1 "^RUNNING  " "$report" 2>/dev/null | cut -c10- || true)
  fails=$(grep -c "^FAIL  " "$report" 2>/dev/null || true)
  if [ "$code" -ge 128 ] || [ "$code" -lt 0 ]; then
    echo "  PASS  control: Blender crashed (exit $code) during \"$running\"; the report on disk names it"
  elif [ "${fails:-0}" -gt 0 ]; then
    echo "  PASS  control: the report has ${fails} FAIL line(s)"
  else
    echo "  FAIL  control: 6d31b90's modules passed the Self-Test (exit $code)"
    status=1
  fi
else
  echo "  SKIP  6d31b90 is not in this repository"
fi
exit $status
