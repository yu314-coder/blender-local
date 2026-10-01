#!/bin/bash
# Stages the embedded interpreter into the app bundle using the Python
# xcframework's own installer.
#
# Apple rejects loose .so files in a bundle (ITMS-90171: "binary file is not
# permitted"), and CPython ships 67 extension modules as .so. BeeWare's
# install_python — which the xcframework carries in build/utils.sh — wraps each
# one as a Frameworks/<dotted.module.name>.framework and leaves a .fwork
# pointer where the .so was. Python's AppleFrameworkLoader reads the .fwork and
# dlopens the framework, so imports work and the bundle validates.
#
# Rolling our own copy of the stdlib was simpler but produced a bundle Apple
# refuses; this defers to the vendor's machinery instead.
set +e

XCF_REL="Vendor/Python.xcframework"
XCF="$SRCROOT/$XCF_REL"
if [ ! -d "$XCF" ]; then
    echo "error: $XCF_REL is missing. Run ./scripts/vendor-python.sh first." >&2
    exit 1
fi

# install_python reads PROJECT_DIR and CODESIGNING_FOLDER_PATH from Xcode.
export PROJECT_DIR="${PROJECT_DIR:-$SRCROOT}"
export CODESIGNING_FOLDER_PATH="${CODESIGNING_FOLDER_PATH:-$TARGET_BUILD_DIR/$WRAPPER_NAME}"

source "$XCF/build/utils.sh"

# Stdlib plus every extension module, each wrapped as a framework.
install_python "$XCF_REL"

PYVER=$(ls -1 "$CODESIGNING_FOLDER_PATH/python/lib" | head -1)

# The bpy shim and the sync module: pure Python, so they need no wrapping.
mkdir -p "$CODESIGNING_FOLDER_PATH/python/site"
rsync -a --delete --exclude '__pycache__' --exclude '*.pyc' \
    "$SRCROOT/Resources/python/site/" "$CODESIGNING_FOLDER_PATH/python/site/"

# Two things CPython ships that this app cannot use, removed from the bundle
# rather than from the xcframework — the vendored copy stays whole, so a future
# `vendor-python.sh` does not have to know about this.
#
#   ensurepip  bootstraps pip, and carries a pip wheel to do it with. Nothing
#              here imports it, an iPad cannot compile the packages pip would
#              fetch, and shipping the means to download and install code is an
#              argument with App Review nobody needs to have (guideline 2.5.2).
#
#   test       CPython's own test suite. 34 MB of code that never runs, full of
#              deliberately strange data — the kind of large third-party string
#              blob that got a sibling app rejected once, for a URL scheme
#              buried inside a vendored package. Dead code still ships its
#              strings, and a scanner cannot tell that nothing calls them.
#
# Checked before removing: nothing under Sources/ or Resources/python imports
# either name.
STDLIB="$CODESIGNING_FOLDER_PATH/python/lib/$PYVER"
for junk in ensurepip test; do
    if [ -d "$STDLIB/$junk" ]; then
        SIZE=$(du -sk "$STDLIB/$junk" | cut -f1)
        rm -rf "$STDLIB/$junk"
        echo "    dropped $junk ($((SIZE / 1024)) MB)"
    fi
done

echo "  Staged Python $PYVER"
echo "    extension frameworks: $(ls -d "$CODESIGNING_FOLDER_PATH/Frameworks"/*.framework 2>/dev/null | wc -l | tr -d ' ')"
echo "    loose .so remaining:  $(find "$CODESIGNING_FOLDER_PATH/python" -name '*.so' 2>/dev/null | wc -l | tr -d ' ')"

# Monaco ships offline alongside the Python dependency. Keep downloaded vendor
# assets on the data volume; MONACO_ROOT can select another pinned checkout.
MONACO_ROOT="${MONACO_ROOT:-/Volumes/D/OfflinAi/Monaco}"
if [ ! -f "$MONACO_ROOT/vs/loader.js" ]; then
    echo "error: Monaco is missing at $MONACO_ROOT (set MONACO_ROOT)." >&2
    exit 1
fi
mkdir -p "$CODESIGNING_FOLDER_PATH/Monaco"
rsync -a --delete "$MONACO_ROOT/vs/" "$CODESIGNING_FOLDER_PATH/Monaco/vs/" || exit 1
cat > "$CODESIGNING_FOLDER_PATH/Monaco/LICENSE.txt" <<'LICENSE'
MIT License

Copyright (c) Microsoft Corporation. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
LICENSE
