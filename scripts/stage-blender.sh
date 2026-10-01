#!/bin/bash
# Stages the real Blender `bpy` from python-ios-lib into the app bundle.
#
#   Blender Local.app/python/lib/python3.14/site-packages/bpy/   428 MB
#   Blender Local.app/python/lib/python3.14/site-packages/numpy/   17 MB
#   Blender Local.app/Frameworks/libusd_ms.framework/            66 MB
#   Blender Local.app/Frameworks/libav*.dylib                    ffmpeg
#
# Device only: the shipped bpy is arm64 with no simulator slice, so simulator
# builds skip this and fall back to the bundled shim. Set BLENDERKIT_SKIP_BPY=1
# to skip it on device too, for a fast build.
set -euo pipefail

[ "${BLENDERKIT_SKIP_BPY:-0}" = "1" ] && { echo "  bpy staging skipped (BLENDERKIT_SKIP_BPY=1)"; exit 0; }

if [ "$PLATFORM_NAME" != "iphoneos" ]; then
    echo "  bpy staging skipped: real bpy is arm64-only, $PLATFORM_NAME uses the shim"
    exit 0
fi

SRC_ROOT="${BLENDERKIT_PYTHON_IOS_LIB:-/Volumes/D/OfflinAi}"
BPY_SRC="$SRC_ROOT/app_packages/site-packages/bpy"
NUMPY_SRC="$SRC_ROOT/app_packages/site-packages/numpy"
FFMPEG_SRC="$SRC_ROOT/Frameworks/ffmpeg"

if [ ! -d "$BPY_SRC" ]; then
    echo "error: no bpy at $BPY_SRC — a device build requires the Blender backend." >&2
    echo "         set BLENDERKIT_PYTHON_IOS_LIB to your python-ios-lib checkout." >&2
    exit 1
fi

APP="$TARGET_BUILD_DIR/$WRAPPER_NAME"
PYVER=$(ls "$SRCROOT/Vendor/Python.xcframework/lib" | grep -E '^python3\.[0-9]+$' | head -1)
SITE="$APP/python/lib/$PYVER/site-packages"
FRAMEWORKS="$APP/Frameworks"

mkdir -p "$SITE" "$FRAMEWORKS"

# 428 MB — rsync so repeat builds only move what changed.
#
# CodeBench's own startup scripts travel inside the bpy package (it is built
# for that app first). They are excluded: in Blender Local they printed
# CodeBench's render messages into this app's console and then failed with
# "No module named 'codebench_blend_view'" on every render, and this app has
# its own viewport and render panel to show the result in.
echo "  Staging bpy (this takes a while on the first build)…"
rsync -a --delete --exclude '__pycache__' --exclude '*.pyc' \
      --exclude 'lib/libusd_ms.dylib' \
      --exclude 'scripts/startup/codebench_*.py' \
      "$BPY_SRC/" "$SITE/bpy/"

# Blender 5.3 dropped `CyclesLightSettings.cast_shadow`, and its own bundled
# FBX importer still writes to it — so importing any FBX that contains a light
# dies with "'CyclesLightSettings' object has no attribute 'cast_shadow'".
# Upstream's bug, in a file this app ships, so it is patched here: the rsync
# above restores the original every build, which is why this runs every build.
FBX_IMPORT="$SITE/bpy/5.3/scripts/addons_core/io_scene_fbx/import_fbx.py"
for FBX_IMPORT in "$SITE"/bpy/*/scripts/addons_core/io_scene_fbx/import_fbx.py; do
    [ -f "$FBX_IMPORT" ] || continue
    python3 - "$FBX_IMPORT" <<'PATCH'
import re, sys
path = sys.argv[1]
text = open(path).read()
guard = 'if hasattr(lamp.cycles, "cast_shadow"):'
if guard in text:
    print("  io_scene_fbx already patched")
else:
    # The indentation is whatever upstream used, and the guarded line has to
    # keep it: matching a fixed indent once produced a file that would not
    # even parse.
    pattern = re.compile(r"^([ \t]*)lamp\.cycles\.cast_shadow = lamp\.use_shadow[ \t]*$", re.M)
    match = pattern.search(text)
    if match:
        indent = match.group(1)
        text = pattern.sub(indent + guard + "  # removed in Blender 5.3\n"
                           + indent + "    lamp.cycles.cast_shadow = lamp.use_shadow",
                           text, count=1)
        open(path, "w").write(text)
        compile(text, path, "exec")   # a file that will not parse is worse than the bug
        print("  patched io_scene_fbx: cast_shadow guarded")
    else:
        print("  note: io_scene_fbx has no cast_shadow line; nothing to patch")
PATCH
done

# Blender's Essentials sculpt brushes (CC0, from Blender 5.2.1; see
# Resources/BlenderAssets/README.md). The bpy above has no datafiles/assets,
# so Sculpt Mode had no brush to stroke with: brush.asset_activate and the
# default brush both load from this file. The rsync above removes it on every
# build, so it is copied on every build.
ESSENTIALS_SRC="$SRCROOT/Resources/BlenderAssets"
for version in "$SITE"/bpy/[0-9]*.[0-9]*; do
    [ -d "$version/datafiles" ] || continue
    mkdir -p "$version/datafiles/assets/brushes"
    cp -f "$ESSENTIALS_SRC/brushes/essentials_brushes-mesh_sculpt.blend" "$version/datafiles/assets/brushes/"
    cp -f "$ESSENTIALS_SRC/blender_assets.cats.txt" "$ESSENTIALS_SRC/LICENSE" "$version/datafiles/assets/"
    echo "  Essentials sculpt brushes staged into $(basename "$version")/datafiles/assets"
done

# numpy travels with bpy.
#
# Blender's own idiom for reading geometry is `foreach_get` into a buffer, and
# in practice that buffer is a numpy array — so a large share of bpy scripts
# open with `import numpy`. Without it they fail on the first line, which is
# what "No module named numpy" was. Same arm64-only story as bpy, so it lands
# in the same place and gets wrapped by the same pass below.
if [ -d "$NUMPY_SRC" ]; then
    echo "  Staging numpy…"
    rsync -a --delete --exclude '__pycache__' --exclude '*.pyc' \
          --exclude 'tests' --exclude '*/tests' \
          "$NUMPY_SRC/" "$SITE/numpy/"
    for meta in "$SRC_ROOT/app_packages/site-packages"/numpy-*.dist-info; do
        [ -d "$meta" ] && rsync -a "$meta" "$SITE/"
    done
else
    echo "  warning: no numpy at $NUMPY_SRC — scripts importing it will fail." >&2
fi

# bpy links @rpath/libusd_ms.framework/libusd_ms, but the shipped file is a
# plain dylib named @rpath/libusd_ms.dylib. Wrap it in a framework and fix the
# framework's own install name — modifying the 222 MB bpy binary instead is
# known to corrupt its symbol table.
USD_FW="$FRAMEWORKS/libusd_ms.framework"
if [ ! -f "$USD_FW/libusd_ms" ] || [ "$BPY_SRC/lib/libusd_ms.dylib" -nt "$USD_FW/libusd_ms" ]; then
    rm -rf "$USD_FW"
    mkdir -p "$USD_FW"
    cp "$BPY_SRC/lib/libusd_ms.dylib" "$USD_FW/libusd_ms"
    install_name_tool -id "@rpath/libusd_ms.framework/libusd_ms" "$USD_FW/libusd_ms" 2>/dev/null
    cat > "$USD_FW/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>libusd_ms</string>
    <key>CFBundleIdentifier</key><string>com.yu314.libusd-ms</string>
    <key>CFBundleName</key><string>libusd_ms</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>MinimumOSVersion</key><string>$IPHONEOS_DEPLOYMENT_TARGET</string>
    <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
</dict>
</plist>
PLIST
fi

# ffmpeg, which bpy links for video sequencer and rendering codecs. These carry
# @rpath install names already, so Frameworks/ is where dyld will find them.
if [ -d "$FFMPEG_SRC" ]; then
    for lib in libavcodec.62 libavdevice.62 libavfilter.11 libavformat.62 \
               libavutil.60 libswresample.6 libswscale.9; do
        src="$FFMPEG_SRC/$lib.dylib"
        [ -f "$src" ] && cp -f "$src" "$FRAMEWORKS/$lib.dylib"
    done
fi

# Apple rejects loose .so files, and bpy's __init__.so is one. Hand it to the
# same BeeWare installer the stdlib extensions go through, so it becomes
# Frameworks/site-packages.bpy.__init__.framework with a .fwork pointer left
# behind — which is exactly how BenchCode ships it.
export PROJECT_DIR="${PROJECT_DIR:-$SRCROOT}"
export CODESIGNING_FOLDER_PATH="${CODESIGNING_FOLDER_PATH:-$APP}"
source "$SRCROOT/Vendor/Python.xcframework/build/utils.sh"
process_dylibs "Vendor/Python.xcframework" "python/lib/$PYVER/site-packages"
echo "  wrapped bpy: $(ls -d "$APP/Frameworks"/site-packages.*.framework 2>/dev/null | wc -l | tr -d ' ') framework(s)"

# Everything Mach-O in the bundle has to carry the app's signature.
if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]; then
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$USD_FW" >/dev/null
    for dylib in "$FRAMEWORKS"/libav*.dylib "$FRAMEWORKS"/libsw*.dylib; do
        [ -f "$dylib" ] && codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
            --timestamp=none "$dylib" >/dev/null
    done
    find "$SITE/bpy" -name '*.so' -print0 | while IFS= read -r -d '' so; do
        codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$so" >/dev/null
    done
fi

echo "  Staged real bpy: $(du -sh "$SITE/bpy" | cut -f1), USD $(du -sh "$USD_FW" | cut -f1)"
