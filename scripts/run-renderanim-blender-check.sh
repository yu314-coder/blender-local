#!/bin/bash
# Render Animation and the Render, Output and World tabs' Python, run the way
# the iPad runs it: Blender 5.2.1 in background mode, factory settings, no 3D
# View area (tests/output/blender/verify.py). Then every video it wrote is
# probed with ffprobe: the codec and the frame count Blender said it wrote.
#
# Skipped, not failed, when Blender is not installed; the probe is skipped
# when ffprobe is not.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
if [ ! -x "$BLENDER" ]; then
  echo "  SKIP  desktop Blender not installed at $BLENDER"
  exit 0
fi
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/blenderlocal-renderanim-blender.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
swiftc -Onone -o "$BUILD/dump" Sources/BlenderLocalBridge/*.swift tests/output/blender/main.swift
"$BUILD/dump" > "$BUILD/calls.txt"
# Blender gets a HOME, BLENDER_USER_RESOURCES and TMPDIR of its own, and is
# started from its work folder: a headless run writes ~/.thumbnails into HOME.
ROOT="$(pwd)"
home="$BUILD/home"; work="$BUILD/work"
mkdir -p "$home/res" "$home/tmp" "$work"
echo "== Blender $("$BLENDER" --version | head -1 | cut -d' ' -f2), headless"
set +e
(cd "$work" && env HOME="$home" BLENDER_USER_RESOURCES="$home/res" TMPDIR="$home/tmp" \
  "$BLENDER" -b --factory-startup --python-exit-code 1 \
  --python "$ROOT/tests/output/blender/verify.py" -- "$BUILD/calls.txt" "$work" > "$BUILD/blender.log" 2>&1)
status=$?
set -e
grep -E "^  (PASS|FAIL)|^\s+\(|^  [a-zA-Z]|^[0-9]+ FAILED|ALL PASS|Error|Traceback|^  File" "$BUILD/blender.log" || true
# Blender's exit code is not the script's when the script raises past the
# checks: the verdict is the script's own last word.
grep -q "^ALL PASS" "$BUILD/blender.log" || status=1
FFPROBE=$(command -v ffprobe || true)
echo
echo "  the videos, probed"
if [ -z "$FFPROBE" ]; then
  echo "  SKIP  ffprobe is not installed"
elif [ -s "$work/videos.txt" ]; then
  while IFS=$'\t' read -r path frames codec; do
    got=$("$FFPROBE" -v error -select_streams v:0 -count_frames \
          -show_entries stream=codec_name,nb_read_frames -of csv=p=0 "$path" 2>&1 | head -1)
    want="$codec,$frames"
    name=$(basename "$path")
    if [ "$got" = "$want" ]; then echo "  PASS  $name: $codec, $frames frames"
    else echo "  FAIL  $name: want $want, ffprobe says $got"; status=1; fi
  done < "$work/videos.txt"
else
  echo "  FAIL  no video was listed"; status=1
fi
exit $status
