#!/bin/bash
# Copies the Python 3.14 xcframework out of a local python-ios-lib checkout into
# Vendor/, which is gitignored. The binaries are ~75 MB, so they are staged
# locally rather than committed.
#
#   ./scripts/vendor-python.sh [path-to-python-ios-lib]
#
# Everything the interpreter needs ends up inside the app bundle, so Blender Local
# runs entirely offline — nothing is fetched at build time or at runtime.
set -euo pipefail

SRC_ROOT="${1:-/Volumes/D/OfflinAi}"
SRC="$SRC_ROOT/Frameworks/Python.xcframework"
DEST="$(cd "$(dirname "$0")/.." && pwd)/Vendor"

if [ ! -d "$SRC" ]; then
    echo "error: no Python.xcframework at $SRC" >&2
    echo "       pass the path to your python-ios-lib checkout:" >&2
    echo "       ./scripts/vendor-python.sh /path/to/python-ios-lib" >&2
    exit 1
fi

mkdir -p "$DEST"
echo "Vendoring Python from $SRC"
rm -rf "$DEST/Python.xcframework"
cp -R "$SRC" "$DEST/Python.xcframework"

VER=$(ls "$DEST/Python.xcframework/lib" | grep -E '^python3\.[0-9]+$' | head -1)
echo "  Python $VER"
echo "  device slice     : $(ls "$DEST/Python.xcframework/ios-arm64/lib-arm64/$VER/lib-dynload" | wc -l | tr -d ' ') extension modules"
echo "  stdlib           : $(ls "$DEST/Python.xcframework/lib/$VER" | wc -l | tr -d ' ') entries"
echo "  total            : $(du -sh "$DEST/Python.xcframework" | cut -f1)"
echo "Done. Run 'xcodegen generate' next."
