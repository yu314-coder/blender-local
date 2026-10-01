#!/bin/bash
# Builds, signs and installs Blender Local on a connected device.
#
# xcodebuild cannot use the Xcode-managed team profile as a manual specifier,
# and there is no Xcode account configured for automatic signing from the
# command line, so the app is built unsigned and signed here instead.
#
#   ./scripts/deploy-device.sh [devicectl-device-id]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The device, identity and profile are this Mac's own, in scripts/local.env,
# which git ignores (scripts/local.env.example).
[ -f "$ROOT/scripts/local.env" ] && . "$ROOT/scripts/local.env"
DEVICE="${1:-${BK_DEVICE:?pass a device id, or set BK_DEVICE in scripts/local.env}}"
PROFILE_UUID="${BK_PROFILE_UUID:?set BK_PROFILE_UUID in scripts/local.env (see local.env.example)}"
IDENTITY="${BK_SIGN_IDENTITY:?set BK_SIGN_IDENTITY in scripts/local.env (see local.env.example)}"
PROFILE="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/$PROFILE_UUID.mobileprovision"

[ -f "$PROFILE" ] || { echo "error: no profile at $PROFILE" >&2; exit 1; }

echo "==> Building (unsigned)"
xcodebuild -project "$ROOT/BlenderLocal.xcodeproj" -scheme BlenderLocal \
    -destination "platform=iOS,id=$DEVICE" -configuration Debug \
    CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error: |Staged |\*\* BUILD" || true

BUILD_DIR=$(xcodebuild -project "$ROOT/BlenderLocal.xcodeproj" -scheme BlenderLocal \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILD_DIR /{print $2; exit}')
APP="$BUILD_DIR/Debug-iphoneos/BlenderLocal.app"
[ -d "$APP" ] || { echo "error: no app at $APP" >&2; exit 1; }

echo "==> Signing"
cp "$PROFILE" "$APP/embedded.mobileprovision"
ENT=$(mktemp -t blenderlocal-ent).plist
security cms -D -i "$PROFILE" > "$ENT.full"
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$ENT.full" > "$ENT"

# Inside-out: nested Mach-O first, then the bundle itself.
find "$APP/Frameworks" -name '*.dylib' -print0 2>/dev/null | while IFS= read -r -d '' f; do
    codesign --force --sign "$IDENTITY" --timestamp=none "$f" >/dev/null
done
for fw in "$APP/Frameworks"/*.framework; do
    [ -d "$fw" ] && codesign --force --sign "$IDENTITY" --timestamp=none "$fw" >/dev/null
done

# Every Python extension module, including Blender's 222 MB bpy.
COUNT=0
while IFS= read -r -d '' so; do
    codesign --force --sign "$IDENTITY" --timestamp=none "$so" >/dev/null
    COUNT=$((COUNT + 1))
done < <(find "$APP/python" -name '*.so' -print0 2>/dev/null)
echo "    signed $COUNT Python extension modules"

codesign --force --sign "$IDENTITY" --entitlements "$ENT" --timestamp=none \
    --generate-entitlement-der "$APP" >/dev/null
rm -f "$ENT" "$ENT.full"

echo "==> Installing ($(du -sh "$APP" | cut -f1))"
xcrun devicectl device install app --device "$DEVICE" "$APP" 2>&1 | tail -3
echo "==> Done. Launch with:"
echo "    xcrun devicectl device process launch --console --device $DEVICE euler.OfflinAi"
