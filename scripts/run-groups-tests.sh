#!/bin/bash
# Vertex groups and shape keys, the Swift half: the record the mirror hands
# over, its merge, what each control of the Data tab's Vertex Groups and Shape
# Keys panels sends, and the modifiers' Vertex Group field. Pure strings; no
# Metal, no Python. What Blender does with it: scripts/run-groups-blender-check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-groups-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" Sources/BlenderLocalBridge/*.swift tests/groups/main.swift
exec "$BUILD/run"
