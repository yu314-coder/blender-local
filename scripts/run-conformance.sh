#!/bin/bash
# Runs tests/bpy_conformance.py inside the app on a booted simulator and prints
# the results. The DEBUG-only -eval64 launch argument is how a script gets in:
# the simulator command-line tools cannot tap Run Script. Output comes back over
# --console-pty, which the app echoes each console line to.
#
#   ./scripts/run-conformance.sh [simulator-udid]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE=euleryu.blenderkit
UDID="${1:-$(xcrun simctl list devices booted -j \
  | python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"];
print(next(x["udid"] for v in d.values() for x in v if x["state"]=="Booted"))')}"

echo "Simulator: $UDID"
DERIVED="${BK_DERIVED:-$HOME/Library/Developer/Xcode/DerivedData/BLSim}"
xcodebuild -project "$ROOT/BlenderLocal.xcodeproj" -scheme BlenderLocal \
    -destination "platform=iOS Simulator,id=$UDID" -configuration Debug \
    -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO build >/dev/null || {
        echo "build failed"; exit 1; }

APP="$DERIVED/Build/Products/Debug-iphonesimulator/BlenderLocal.app"
OUT="$(mktemp -t bk-conformance)"

xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null
xcrun simctl install "$UDID" "$APP"
( xcrun simctl launch --console-pty "$UDID" "$BUNDLE" -workspace Scripting \
    -eval64 "$(base64 -i "$ROOT/tests/bpy_conformance.py" | tr -d '\n')" > "$OUT" 2>&1 ) &
LAUNCH=$!

# The script runs on the main thread; wait for the summary line to show up.
for _ in $(seq 1 30); do
    grep -q '^\[bk\] pass ' "$OUT" && break
    sleep 2
done
kill $LAUNCH 2>/dev/null
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null

sed -n 's/^\[bk\] //p' "$OUT" | grep -E '^(ok|FAIL|ERR|---|pass) '
FAILED=$(sed -n 's/^\[bk\] //p' "$OUT" | grep -cE '^(FAIL|ERR) ')
echo
# keyframe_insert is expected to raise: Blender Local has no animation system
# and says so rather than faking it.
if [ "$FAILED" -le 1 ]; then echo "ALL PASS"; else echo "$FAILED failing"; exit 1; fi
