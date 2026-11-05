#!/bin/bash
# MainWait hands the script thread's onMain calls to the main thread while it
# waits for a script (BpySession.evaluateKeepingResponsive). A slip there does
# not give a wrong answer; it stops the app, and only when the timing is
# unlucky — so the test makes it unlucky 200,000 times.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/blenderlocal-mainwait-tests"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/run" Sources/BlenderLocalBridge/MainThread.swift tests/mainwait/main.swift
exec "$BUILD/run"
