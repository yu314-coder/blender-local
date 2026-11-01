#!/bin/bash
# More ▸ Operator Search runs any operator by name through
# _blenderkit_sync.run_operator. Its code starts with an import, so
# BpyModeGuard never bracketed it, and it checked only the poll: Multires's
# Apply Base and Unsubdivide pass their poll in Edit Mode and there segfaulted
# the app. This runs, in desktop Blender with the app's context:
#
#   1. verify.py — the menus' mode rule, the mode put back, what is refused and
#      why, what the form shows, and the Multires calls, with the old
#      run_operator crashing on the same call as the negative control;
#   2. the sweep — every operator the search lists, with its defaults, through
#      run_operator: object.*, mesh.* and uv.* on three fixtures from Object,
#      Edit, Sculpt and Texture Paint, every other module on a cube from the
#      same four. A Blender per fixture and mode, restarted after anything that
#      crashes it, so one crash names its operator and the sweep goes on.
#      Passes only with no crash and no operator running past a minute;
#   3. the same for every module, from a file saved in Sculpt Mode, Weight
#      Paint or Vertex Paint and opened as the app opens its autosave, with no
#      3D View tool for the mode and the app's guards installed (round 4's
#      fix round: a brush pick crashed Blender there and nowhere else).
#
# About four minutes. The sweep's Blender gets a home of its own under TMPDIR,
# so an operator that writes a file writes it there, and sweep.py refuses to
# start without one. Operators that reach outside Blender (a browser, Finder,
# another Blender, the recent-files list) are left out by name, and anything
# they would start is refused inside the sweep's Blender (keep_to_blender).
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
[ -x "$BLENDER" ] || { echo "  SKIP  desktop Blender not installed"; exit 0; }
# Under set -e a failing verify.py would end the script on this pipeline,
# before its status is read and before the sweep runs.
set +e
# verify.py runs operators too, so its Blender gets a home of its own as the
# sweep's does: nothing it runs may write this Mac's own Blender settings.
verify_home="${TMPDIR:-/tmp}/blenderlocal-opsearch-verify-home"
mkdir -p "$verify_home"
# From that folder, not the repo: what Blender writes into its working folder
# stays out of the tree. The sweep's Blenders start in their own (drive.py).
ROOT="$(pwd)"
cd "$verify_home"
HOME="$verify_home" BLENDER_USER_RESOURCES="$verify_home/res" \
"$BLENDER" -b --factory-startup --python "$ROOT/tests/opsearch/blender/verify.py" 2>&1 \
  | grep -E "^  (PASS|FAIL)|^==|^ALL PASS|FAILED$"
status=${PIPESTATUS[0]}
cd "$ROOT"
set -e
echo
echo "== every operator the search lists, through run_operator =="
python3 tests/opsearch/blender/drive.py new && sweep=0 || sweep=$?
python3 tests/opsearch/blender/drive.py new mods=rest && rest=0 || rest=$?
echo
echo "== every operator, from a file opened in a paint mode with no 3D View tool for it =="
python3 tests/opsearch/blender/drive.py new opened && opened=0 || opened=$?
if [ "$status" -eq 0 ] && [ "$sweep" -eq 0 ] && [ "$rest" -eq 0 ] && [ "$opened" -eq 0 ]; then
  echo "ALL PASS"
else
  echo "FAILED (verify $status, sweep $sweep, rest $rest, opened $opened)"; exit 1
fi
