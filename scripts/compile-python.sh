#!/bin/bash
# Compiles every staged .py to a .pyc beside it.
#
# The bundle is read-only, so CPython cannot keep what it compiles: without
# these, each launch compiles the standard library's and Blender's own startup
# scripts from source again. Measured on an M4 (launch trace, `import bpy`):
# 1.7 s from source, 1.0 s from these.
#
# The .pyc are "unchecked hash" ones: CPython loads them without reading the
# source's date, which an install does not keep. They are right as long as
# they are compiled from the staged source, so this runs on every build, after
# the last staging step, and compiles all of it again.
set -euo pipefail

APP="${CODESIGNING_FOLDER_PATH:-$TARGET_BUILD_DIR/$WRAPPER_NAME}"
PYLIB="$APP/python/lib"
[ -d "$PYLIB" ] || { echo "  no staged Python: nothing to compile"; exit 0; }
PYVER=$(ls -1 "$PYLIB" | head -1)          # python3.14

# The host's Python of the same minor version: a .pyc is read only by the
# version that wrote it.
HOST=""
for candidate in "$(command -v "$PYVER" || true)" "/opt/homebrew/bin/$PYVER" "/usr/local/bin/$PYVER"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { HOST="$candidate"; break; }
done
if [ -z "$HOST" ]; then
    echo "warning: no $PYVER on this Mac: the app's Python is not compiled, and it launches slower" >&2
    exit 0
fi

# Out of date ones first: a .pyc whose source is gone or changed must not stay.
find "$APP/python" -name '__pycache__' -type d -prune -exec rm -rf {} +
"$HOST" -m compileall -q -f -j 0 --invalidation-mode unchecked-hash "$APP/python" >/dev/null || true
echo "  compiled $(find "$APP/python" -name '*.pyc' | wc -l | tr -d ' ') of $(find "$APP/python" -name '*.py' | wc -l | tr -d ' ') Python files with $HOST"
