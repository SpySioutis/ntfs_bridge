#!/bin/bash
# Package NTFSBridge.app from a release build.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="NTFSBridge"
DIST="dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "==> Building release..."
swift build -c release

BIN=".build/release/NTFSBridgeApp"
if [ ! -f "$BIN" ]; then BIN=".build/arm64-apple-macosx/release/NTFSBridgeApp"; fi
if [ ! -f "$BIN" ]; then echo "release binary not found"; exit 1; fi

echo "==> Assembling ${APP}..."
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

cp "$BIN" "$MACOS/$APP_NAME"
chmod +x "$MACOS/$APP_NAME"

VERSION="${VERSION:-1.0.0}"
cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>com.example.ntfsbridge</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSUIElement</key><false/>
</dict>
</plist>
EOF

cp NTFSBridge.entitlements "$CONTENTS/NTFSBridge.entitlements" 2>/dev/null || true

# Bundle the NTFS engine + licenses (staged by scripts/bundle-engine.sh).
# BackendManager resolves these first; without them the app honestly
# reports system-only (.system) or read-only (.none) status.
if [ -d Resources ]; then
  cp -R "Resources/." "$RESOURCES/"
  if [ -f "$RESOURCES/bin/ntfs-3g" ]; then
    echo "Bundled engine: $(cat "$RESOURCES/engine-info.json" 2>/dev/null || echo 'ntfs-3g (no engine-info.json)')"
  else
    echo "(no bundled ntfs-3g in Resources/bin — app will use system backends only)"
  fi
fi
# Ad-hoc sign so Gatekeeper treats the bundle sanely on the build Mac.
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "(codesign skipped)"

echo "==> Done: ${APP}"
ls -la "$APP"
