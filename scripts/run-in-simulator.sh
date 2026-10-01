#!/bin/bash
# Build, install and launch in the simulator — with a script, optionally.
#
#   ./scripts/run-in-simulator.sh [-w Scripting] [script.py]
#
# ARCHS=arm64 is not optional and is the whole reason this script exists.
#
# The Python xcframework's simulator slice keeps its standard library in
# per-architecture folders — `lib-arm64` and `lib-x86_64` — and its installer
# copies from `lib-$ARCHS`. A generic simulator destination sets ARCHS to
# "arm64 x86_64", so it looks for a folder named `lib-arm64 x86_64`, does not
# find it, and copies no standard library at all. The build still succeeds; the
# only sign is one rsync line among thousands. The app then starts, Python
# starts, and every import fails with `No module named 'math'` — which means
# `import bpy` fails, which means every operator in the interface fails with a
# NameError. It looks exactly like the app being broken.
set -euo pipefail
cd "$(dirname "$0")/.."

DEV="${BK_SIM:-iPad Pro 13-inch (M5)}"
UDID=$(xcrun simctl list devices available | grep -F "$DEV (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
[ -n "$UDID" ] || { echo "no simulator matching '$DEV'"; exit 1; }

WORKSPACE=""
if [ "${1:-}" = "-w" ]; then WORKSPACE="-workspace $2"; shift 2; fi

xcodebuild -project BlenderLocal.xcodeproj -scheme BlenderLocal \
    -destination "platform=iOS Simulator,id=$UDID" -configuration Debug \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build | tail -2

APP=$(xcodebuild -project BlenderLocal.xcodeproj -scheme BlenderLocal \
        -destination "platform=iOS Simulator,id=$UDID" -configuration Debug \
        -showBuildSettings 2>/dev/null \
      | awk '$1 == "BUILT_PRODUCTS_DIR" {print $3; exit}')/BlenderLocal.app
[ -d "$APP" ] || { echo "no app at $APP"; exit 1; }

# The staged standard library is the thing that silently goes missing.
MODULES=$(ls "$APP/python/lib/python3.14" 2>/dev/null | wc -l | tr -d ' ')
echo "  staged stdlib entries: $MODULES"
[ "$MODULES" -gt 100 ] || { echo "the standard library did not stage — check ARCHS"; exit 1; }

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl terminate "$UDID" euleryu.blenderkit 2>/dev/null || true

EVAL=""
if [ -n "${1:-}" ] && [ -f "$1" ]; then EVAL="-eval64 $(base64 < "$1")"; fi
exec xcrun simctl launch --console-pty "$UDID" euleryu.blenderkit $WORKSPACE $EVAL
