#!/bin/bash
# Blender's pie menus: where each item goes, which one the pointer chooses, and
# what letting go of the key does — held to Blender's own rules
# (interface_layout.cc, interface_query.cc, interface_handlers.cc, 5.2.1).
# Pure Swift; the menus the pies hold are checked by the names suites.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-pie-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" Sources/BlenderLocalBridge/PieGeometry.swift tests/pie/main.swift
exec "$BUILD/run"
