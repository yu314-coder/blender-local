#!/bin/bash
# The Timeline as an animation editor, its Swift half, on the Mac: which
# column a finger is on, the frames a box spans, where a dragged key lands
# under Blender's Snap, the numbers and Use Timecode's time along the top,
# the markers' layout and Jump to Marker, the view's zoom, pan and framing,
# the report's bytes, the menus by Blender's names, and what each control
# sends — a selection without the mirroring pass and one undo step unless it
# changed nothing, an edit through it — against a runtime that records what
# would reach Blender. What Blender makes of it is
# scripts/run-timeline-blender-check.sh. Builds in a private temporary
# directory, because other suites run at the same time.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/blenderlocal-timeline-tests.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
swiftc -O -o "$BUILD/run" \
  Sources/BlenderLocalBridge/*.swift \
  tests/timeline/main.swift
"$BUILD/run"
