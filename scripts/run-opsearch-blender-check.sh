#!/bin/bash
# More ▸ All Blender Tools runs any operator by name through
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
#      Passes only with no crash and no operator running past a minute.
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
"$BLENDER" -b --factory-startup --python tests/opsearch/blender/verify.py 2>&1 \
  | grep -E "^  (PASS|FAIL)|^==|^ALL PASS|FAILED$"
status=${PIPESTATUS[0]}
set -e
echo
echo "== every operator the search lists, through run_operator =="
python3 tests/opsearch/blender/drive.py new && sweep=0 || sweep=$?
python3 tests/opsearch/blender/drive.py new mods=rest && rest=0 || rest=$?
if [ "$status" -eq 0 ] && [ "$sweep" -eq 0 ] && [ "$rest" -eq 0 ]; then
  echo "ALL PASS"
else
  echo "FAILED (verify $status, sweep $sweep, rest $rest)"; exit 1
fi
