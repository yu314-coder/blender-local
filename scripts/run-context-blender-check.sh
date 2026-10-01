#!/bin/bash
# temp_override off the main thread, in Blender background mode, which has a
# window and a screen on the main thread only, like the iPad.
#
# Checks that the module the app ships (Resources/python/site/_blenderkit_context.py)
# keeps a worker thread's override from wiping the main thread's window and
# screen, in every shape a script uses; that the override still works on the
# main thread; and, last, that Blender's own temp_override does lose them.
#
# Skipped, not failed, when Blender is not installed.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
"$BLENDER" -b --factory-startup --python-exit-code 1 --python tests/context/blender/verify.py 2>&1 \
  | grep -vE '^(Blender [0-9]|Read prefs|$)'
exit "${PIPESTATUS[0]}"
