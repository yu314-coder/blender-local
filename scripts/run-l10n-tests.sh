#!/bin/bash
# The interface languages on the Mac: every generated table is well formed
# (values and line breaks kept) and the lookup translates text, puts values
# into their places, and leaves names and numbers alone.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-l10n-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" Sources/BlenderLocalUI/Theme/Localization.swift tests/l10n/main.swift
exec "$BUILD/run"
