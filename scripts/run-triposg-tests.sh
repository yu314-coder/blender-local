#!/bin/bash
# Image to 3D Model's full-3D pieces that need no weights: safetensors and the
# float16 conversion, DINOv2's position-embedding resize, the flow's inputs,
# marching cubes and the coarse-to-fine surface, the picture, the viewpoint
# fit and the bake. The network itself is checked against PyTorch by
# run-triposg-parity.sh, which needs the weights.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-triposg-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" Sources/BlenderLocalBridge/*.swift tests/triposg/main.swift
exec "$BUILD/run"
