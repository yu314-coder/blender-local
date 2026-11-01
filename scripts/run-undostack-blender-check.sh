#!/bin/bash
# Blender's undo stack is there whenever an operator could need it
# (tests/undostack/blender/case.py).
#
# Without one, Sculpt Mode's undo code segfaults Blender: entering Sculpt Mode
# with the undo argument on, or a mask fill or Face Sets ▸ Initialize in it.
# The app's history leaves Blender with none until its first step (deferred
# while an object is in another mode, as an autosave can open), and a file
# load frees it. Two guards make it: the history's (`_blenderkit_undo.
# ensure_stack`, with its first step and after a load) and the operators'
# (`_blenderkit_context.require_undo_stack`, as any operator runs in Sculpt
# Mode or into it), which also holds where no history step came first — a
# console line that does not read as Python, a launch whose recovery file
# opened in Sculpt Mode (round 4's review of group 7).
#
# Each case runs in a Blender of its own, the way the app reaches it, and has
# to survive with both guards and with each alone; off the main thread, where
# no stack can be made, it is refused in words. Then the guards are switched
# off, and the same calls have to crash — the check can fail. Those negative
# controls crash desktop Blender on purpose: each leaves a Blender-*.ips in
# ~/Library/Logs/DiagnosticReports (`mask_flood_fill_exec`, `face_sets_init`,
# `push_enter_sculpt_mode` ← `ED_undosys_stack_memfile_id_changed_tag`).
#
# Each Blender gets a home of its own under the work directory, so nothing
# reaches this Mac's Blender settings. Skipped, not failed, when Blender is not
# installed.
set -uo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/blenderlocal-undostack.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
fail=0
run() {  # run <case> [switch] -> sets out, code
  local dir="$WORK/$1${2:+-$2}"
  mkdir -p "$dir/home/res"
  out="$(cd "$dir" && HOME="$dir/home" BLENDER_USER_RESOURCES="$dir/home/res" TMPDIR="$dir" \
    "$BLENDER" -b --factory-startup --python "$OLDPWD/tests/undostack/blender/case.py" -- "$@" 2>&1)"
  code=$?
}
survives() {  # survives <case> [switch]
  run "$@"
  line="$(grep '^SURVIVED' <<<"$out")"
  state="$(grep '^STATE' <<<"$out" | tr '\n' ' ')"
  if [ "$code" = 0 ] && [ -n "$line" ] && ! grep -q "steps 0" <<<"$line"; then
    echo "  PASS  $1${2:+ ($2)}: $line ($state)"
  else
    echo "  FAIL  $1${2:+ ($2)}: exit $code; $state; $(tail -3 <<<"$out" | tr '\n' ' ')"; fail=1
  fi
}
crashes() {  # crashes <case> <switch>
  run "$@"
  if [ "$code" != 0 ] && grep -q '^ABOUT TO RUN' <<<"$out" && ! grep -q '^SURVIVED\|^REFUSED' <<<"$out"; then
    echo "  PASS  $1 ($2): exit $code after \"$(grep '^ABOUT TO RUN' <<<"$out")\""
  else
    echo "  FAIL  $1 ($2) did not crash: exit $code; $(tail -3 <<<"$out" | tr '\n' ' ')"; fail=1
  fi
}
HISTORY_CASES="deferred-sculpt-undo deferred-mask load-homefile load-mainfile"
UNSTEPPED_CASES="launch-sculpt console-mask console-search console-in-view"

echo
echo "With both guards: each call that crashed runs"
for c in $HISTORY_CASES $UNSTEPPED_CASES; do survives "$c"; done

echo
echo "Off the main thread, where no stack can be made: refused in words"
run offmain-mask
if [ "$code" = 0 ] && grep -q "^REFUSED bpy.ops.paint.mask_flood_fill was not run: Sculpt Mode keeps its undo" <<<"$out" \
   && ! grep -q '^SURVIVED' <<<"$out"; then
  echo "  PASS  offmain-mask: $(grep '^REFUSED' <<<"$out" | cut -c1-110)… ($(grep '^STATE after' <<<"$out"))"
else
  echo "  FAIL  offmain-mask: exit $code; $(tail -3 <<<"$out" | tr '\n' ' ')"; fail=1
fi

echo
echo "Each guard alone"
for c in $HISTORY_CASES $UNSTEPPED_CASES; do survives "$c" context-only; done
for c in $HISTORY_CASES; do survives "$c" history-only; done

echo
echo "Without them (the negative controls): the same calls crash Blender"
for c in $HISTORY_CASES; do crashes "$c" negative; done
# Where no history step came first, the history's guard alone does not hold.
for c in launch-sculpt console-mask; do crashes "$c" history-only; done
echo
[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILED"
exit "$fail"
