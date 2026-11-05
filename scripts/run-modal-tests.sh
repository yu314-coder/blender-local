#!/bin/bash
# Blender's G, R and S from the keyboard: X, Y and Z cycling the orientation as
# transform_event_xyz_constraint does, and typed numbers (NumInput).
# Pure Swift; the drag they steer is the gizmo's (run-gizmo-tests.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-modal-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" Sources/BlenderLocalBridge/ModalTransformInput.swift tests/modal/main.swift
exec "$BUILD/run"
