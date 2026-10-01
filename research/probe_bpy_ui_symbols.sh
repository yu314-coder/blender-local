#!/usr/bin/env bash
# Does the shipped iOS bpy contain Blender's interface layer?
# Answers whether Blender's real UI can be switched on (Route A) or must be
# rebuilt natively (Route B). Run against a built CodeBench.app.
set -u
APP="${1:-/Volumes/D/xcode/DerivedData/Build/Products/Release-iphoneos/CodeBench.app}"
BIN="$APP/Frameworks/site-packages.bpy.__init__.framework/site-packages.bpy.__init__"
[ -f "$BIN" ] || { echo "bpy binary not found at $BIN"; exit 1; }
printf 'bpy binary: %.0f MB\n\n' "$(( $(stat -f%z "$BIN") / 1048576 ))"
for sym in GHOST_ wm_event WM_operator ED_screen ED_space UI_block UI_but screen_draw; do
  printf '  %-12s %s\n' "$sym" "$(strings "$BIN" 2>/dev/null | grep -c "$sym")"
done
echo
echo 'UI_block/UI_but/screen_draw == 0  ->  headless build, no Blender UI (Route B)'
