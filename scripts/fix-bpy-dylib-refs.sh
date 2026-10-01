#!/bin/bash
# Repoints bpy at the wrapped ffmpeg frameworks.
#
# wrap-loose-dylibs.sh turns each loose Frameworks/libavcodec.62.dylib into
# Frameworks/libavcodec_62.framework/libavcodec_62 and rewrites the references
# in everything it scans — but it walks BenchCode's app_packages/ layout, and
# Blender Local keeps bpy under python/lib/pythonX.Y/site-packages/. So bpy is
# left asking for @rpath/libavcodec.62.dylib, which no longer exists, and it
# would fail at dlopen.
#
# This rewrites bpy's load commands to match, then re-signs it.
# Must run AFTER wrap-loose-dylibs.sh.
set -euo pipefail

APP="${1:-$TARGET_BUILD_DIR/$WRAPPER_NAME}"
[ -d "$APP" ] || { echo "fix-bpy-refs: no app at $APP"; exit 0; }

BPY=$(find "$APP/python" -name "__init__.so" -path "*bpy*" 2>/dev/null | head -1)
if [ -z "$BPY" ]; then
    STUB=$(find "$APP/python" -name "__init__.fwork" -path "*/bpy/*" -print -quit)
    if [ -n "$STUB" ]; then
        REL=$(tr -d '\r\n' < "$STUB")
        case "$REL" in
            Frameworks/*) BPY="$APP/$REL" ;;
            *) echo "fix-bpy-refs: unexpected bpy framework pointer: $REL" >&2; exit 1 ;;
        esac
        [ -f "$BPY" ] || { echo "fix-bpy-refs: missing bpy framework: $BPY" >&2; exit 1; }
    fi
fi
[ -n "$BPY" ] || { echo "fix-bpy-refs: no bpy in the bundle (shim build) — nothing to do"; exit 0; }

changed=0
for ref in $(/usr/bin/otool -L "$BPY" 2>/dev/null | awk '/@rpath\/.*\.dylib/ {print $1}'); do
    base="${ref##*/}"                      # libavcodec.62.dylib
    stem="${base%.dylib}"                  # libavcodec.62
    fw="${stem//./_}"                      # libavcodec_62
    new="@rpath/${fw}.framework/${fw}"
    if [ -f "$APP/Frameworks/${fw}.framework/${fw}" ]; then
        /usr/bin/install_name_tool -change "$ref" "$new" "$BPY" 2>/dev/null \
            && { echo "  $base -> ${fw}.framework/${fw}"; changed=$((changed+1)); }
    else
        echo "  WARNING: no wrapped framework for $base"
    fi
done

if [ "$changed" -gt 0 ]; then
    # install_name_tool invalidates the signature; re-sign or the app will not
    # launch. Ad-hoc here is fine: -exportArchive re-signs for distribution.
    IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY_NAME:-${EXPANDED_CODE_SIGN_IDENTITY:--}}"
    [ "$IDENTITY" = "" ] && IDENTITY="-"
    /usr/bin/codesign --force --sign "$IDENTITY" --timestamp=none "$BPY" >/dev/null 2>&1
    echo "fix-bpy-refs: rewrote $changed reference(s) and re-signed bpy"
else
    echo "fix-bpy-refs: nothing to rewrite"
fi

# Prove it: every remaining @rpath reference must resolve inside Frameworks/.
missing=0
for ref in $(/usr/bin/otool -L "$BPY" 2>/dev/null | awk '/@rpath\// {print $1}'); do
    [ -e "$APP/Frameworks/${ref#@rpath/}" ] || { echo "  UNRESOLVED: $ref"; missing=1; }
done
[ "$missing" -eq 0 ] && echo "fix-bpy-refs: all bpy dependencies resolve" \
                     || { echo "fix-bpy-refs: SOME DEPENDENCIES UNRESOLVED"; exit 1; }
