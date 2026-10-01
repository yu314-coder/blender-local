#!/bin/bash
# Archive Blender Local, export an .ipa, validate it, and upload to App Store
# Connect. Every step that can fail quietly is checked, because each failure
# costs a build number that cannot be reused.
#
#   ./scripts/push-appstore.sh <build-number>
set -euo pipefail

BUILD="${1:?usage: push-appstore.sh <build-number>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${BK_OUT:-/Volumes/D/OfflinAi/blenderlocal-release}"
ARCHIVE="$OUT/BlenderLocal-$BUILD.xcarchive"
EXPORT="$OUT/export-$BUILD"
# The App Store Connect key and issuer IDs are this Mac's own, in
# scripts/local.env, which git ignores (scripts/local.env.example).
[ -f "$ROOT/scripts/local.env" ] && . "$ROOT/scripts/local.env"
KEY_ID="${BK_ASC_KEY_ID:?set BK_ASC_KEY_ID in scripts/local.env (see local.env.example)}"
ISSUER="${BK_ASC_ISSUER:?set BK_ASC_ISSUER in scripts/local.env (see local.env.example)}"
[ -f "$ROOT/ExportOptions.plist" ] || {
    echo "no ExportOptions.plist: copy ExportOptions.example.plist and set your teamID"; exit 1; }

mkdir -p "$OUT"

# A release Xcode only. App Store Connect rejects an upload built by a beta
# Xcode, and a beta can sit beside the release one with either selected. A
# beta's build number has four digits starting with 5 (27A5218g); a
# release's has fewer (27A266a, 17F42), with or without a letter. Whichever `xcode-select -p` names is the one that builds.
XCODE_BUILD=$(xcodebuild -version | awk '/Build version/ {print $3}')
echo "== $(xcodebuild -version | head -1) ($XCODE_BUILD), from $(xcode-select -p) =="
case "$XCODE_BUILD" in
    [0-9]*[A-Z]5[0-9][0-9][0-9]*) echo "that is a beta Xcode: select a release one with sudo xcode-select -s <Xcode.app>"; exit 1 ;;
esac

echo "== regenerating the project at build $BUILD =="
( cd "$ROOT" && CURRENT_PROJECT_VERSION="$BUILD" xcodegen generate >/dev/null )

echo "== archiving =="
xcodebuild -project "$ROOT/BlenderLocal.xcodeproj" -scheme BlenderLocal \
    -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    archive | tail -3

# The built plist is the only place worth reading these back from: a key set
# without the INFOPLIST_KEY_ prefix silently never reaches it.
PLIST="$ARCHIVE/Products/Applications/BlenderLocal.app/Info.plist"
echo "== declared in the built app =="
for key in CFBundleShortVersionString CFBundleVersion ITSAppUsesNonExemptEncryption; do
    printf '  %-32s %s\n' "$key" \
      "$(/usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" 2>/dev/null || echo '(missing)')"
done
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")" = "$BUILD" ] || {
    echo "build number did not reach the app"; exit 1; }

# The runtime decides whether Blender's own bpy is present by looking for one
# of a few filenames, and the build renames that file after staging it: the .so
# becomes a .fwork when the binary is moved into Frameworks/. When those two
# disagree the app runs the real module while reporting the shim, and silently
# stops mirroring Blender's scene into the viewport — nine builds shipped that
# way. So check the bundle against the names the runtime actually looks for.
BPYDIR="$ARCHIVE/Products/Applications/BlenderLocal.app/python/lib/python3.14/site-packages/bpy"
if [ -d "$BPYDIR" ]; then
    NAMES=$(sed -n 's/.*let entryPoints = \[\(.*\)\].*/\1/p' \
        "$ROOT/Sources/BlenderLocalBridge/Python/EmbeddedBpyRuntime.swift" | tr -d '" ' | tr ',' ' ')
    [ -n "$NAMES" ] || { echo "could not read entryPoints from the runtime"; exit 1; }
    FOUND=
    for n in $NAMES; do [ -f "$BPYDIR/$n" ] && FOUND="$n"; done
    echo "== staged bpy =="
    echo "  runtime looks for: $NAMES"
    echo "  bundle has:        ${FOUND:-none}"
    [ -n "$FOUND" ] || { echo "the app would run real bpy but report the shim"; exit 1; }
fi

# By standing instruction, the content check runs on every push, and it runs on
# the built binary rather than on the source: a DEBUG launch argument is only
# absent if `strings` cannot find it in what ships. The same pass looks for
# `itms-services`/`itms-apps` anywhere in the bundle (2.5.2, which has cost a
# build before) and for ensurepip/test staged into the Python standard library.
# It runs here, between the archive and the export, because a rejection after
# the upload costs a build number that cannot be reused.
echo "== content scan =="
python3 "$ROOT/scripts/scan-app.py" \
    "$ARCHIVE/Products/Applications/BlenderLocal.app" release \
    | sed 's/^/  /' || { echo "content scan found problems"; exit 1; }

echo "== exporting =="
rm -rf "$EXPORT"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$ROOT/ExportOptions.plist" \
    -exportPath "$EXPORT" | tail -3
IPA="$EXPORT/BlenderLocal.ipa"
[ -f "$IPA" ] || { echo "no ipa produced"; exit 1; }

# The build number the ipa will actually go up as. Unless ExportOptions.plist says
# manageAppVersionAndBuildNumber = false, the export quietly renumbers a build to one
# past the latest in App Store Connect — pushes 26 and 27 went up as 28 and 29 while
# this script, reading the archive, reported 26 and 27. So read it from the ipa, and
# stop if the export changed it: a stale number should fail here, not be replaced.
UPLOADED=$(unzip -p "$IPA" "Payload/BlenderLocal.app/Info.plist" | plutil -extract CFBundleVersion raw -o - -)
echo "== build number in the ipa: $UPLOADED =="
[ "$UPLOADED" = "$BUILD" ] || { echo "the export changed the build number from $BUILD to $UPLOADED"; exit 1; }

# ITMS-90171: a Mach-O anywhere in the Payload that is not inside a bundle is
# rejected. Scan the whole Payload, not just inside the .app — a stray object
# file beside it fails the same way, and each attempt burns a build number.
echo "== payload scan =="
SCAN="$(mktemp -d)"; unzip -q "$IPA" -d "$SCAN"
STRAY=$(find "$SCAN/Payload" -maxdepth 1 -type f | wc -l | tr -d ' ')
BAK=$(find "$SCAN/Payload" \( -name '*.bak' -o -name '*.so.*' \) | wc -l | tr -d ' ')
LINK=$(find "$SCAN/Payload" -type l | wc -l | tr -d ' ')
echo "  loose files beside the app: $STRAY   .bak/.so.N: $BAK   symlinks: $LINK"
rm -rf "$SCAN"
[ "$STRAY" = 0 ] && [ "$BAK" = 0 ] || { echo "payload is not clean"; exit 1; }

echo "== validating with Apple =="
xcrun altool --validate-app -f "$IPA" -t ios \
    --apiKey "$KEY_ID" --apiIssuer "$ISSUER" 2>&1 | tail -5

echo "== uploading =="
xcrun altool --upload-app -f "$IPA" -t ios \
    --apiKey "$KEY_ID" --apiIssuer "$ISSUER" 2>&1 | tail -5
