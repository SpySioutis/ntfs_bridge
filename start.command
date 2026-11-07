#!/bin/bash
# NTFS Bridge — double-click to start.
# Builds the app on first run (one time), then opens it.
set -u
cd "$(dirname "$0")"

APP="dist/NTFSBridge.app"
BIN="$APP/Contents/MacOS/NTFSBridge"

if [ ! -x "$BIN" ]; then
    echo "NTFS Bridge is not built yet — building now (one time, takes a few minutes)…"
    ./scripts/build-app.sh || { echo "BUILD FAILED — see the errors above."; exit 1; }
fi

echo "Opening NTFS Bridge…"
open "$APP"
