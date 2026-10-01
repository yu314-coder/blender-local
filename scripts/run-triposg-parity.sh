#!/bin/bash
# The Swift/Metal TripoSG (Sources/BlenderLocalBridge/TripoSGModel.swift) against
# VAST-AI's PyTorch implementation, number by number.
#
# Needs the weights and a reference made by tests/triposg/make_reference.py,
# neither of which ships or stays on disk:
#   BK_TRIPOSG_WEIGHTS=/path/TripoSG BK_TRIPOSG_REFERENCE=/path/ref ./scripts/run-triposg-parity.sh
# Skipped, not failed, without them.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${BK_TRIPOSG_WEIGHTS:-}" ] || [ ! -d "${BK_TRIPOSG_WEIGHTS:-}" ] || [ ! -d "${BK_TRIPOSG_REFERENCE:-}" ]; then
  echo "  SKIP  set BK_TRIPOSG_WEIGHTS and BK_TRIPOSG_REFERENCE (see tests/triposg/make_reference.py)"
  exit 0
fi
BUILD="${TMPDIR:-/tmp}/blenderlocal-triposg-parity"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" Sources/BlenderLocalBridge/*.swift tests/triposg/parity/main.swift
exec "$BUILD/run" "$BK_TRIPOSG_WEIGHTS" "$BK_TRIPOSG_REFERENCE"
