#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Wing Multitrack Renamer"
BUILD_DIR="$ROOT_DIR/build-native"
DIST_DIR="$ROOT_DIR/dist-native"
APP_DIR="$DIST_DIR/$APP_NAME.app"
BIN_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
PLIST_PATH="$APP_DIR/Contents/Info.plist"
BIN_PATH="$BIN_DIR/$APP_NAME"
ICON_SOURCE="$ROOT_DIR/iconrenamer.png"
ICON_PATH="$RES_DIR/AppIcon.icns"
ARM64_BIN="$BUILD_DIR/$APP_NAME-arm64"
X64_BIN="$BUILD_DIR/$APP_NAME-x86_64"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Lev Aranovich (SX22W5X23G)}"
ENABLE_SIGNING="${ENABLE_SIGNING:-1}"

rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$BIN_DIR" "$RES_DIR"

if [[ -f "$ICON_SOURCE" ]]; then
  ICON_SOURCE="$ICON_SOURCE" ICON_PATH="$ICON_PATH" python3 - <<'PY'
import os
from PIL import Image

source = os.environ["ICON_SOURCE"]
target = os.environ["ICON_PATH"]
sizes = [(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)]

image = Image.open(source)
image.save(target, format="ICNS", sizes=sizes)
PY
fi

xcrun swiftc \
  -target arm64-apple-macos13.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -O \
  -framework SwiftUI \
  -framework AppKit \
  -framework UniformTypeIdentifiers \
  "$ROOT_DIR/NativeRenamerCore.swift" \
  "$ROOT_DIR/WingSnapWavRenamerNativeApp.swift" \
  -o "$ARM64_BIN"

xcrun swiftc \
  -target x86_64-apple-macos13.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -O \
  -framework SwiftUI \
  -framework AppKit \
  -framework UniformTypeIdentifiers \
  "$ROOT_DIR/NativeRenamerCore.swift" \
  "$ROOT_DIR/WingSnapWavRenamerNativeApp.swift" \
  -o "$X64_BIN"

lipo -create "$ARM64_BIN" "$X64_BIN" -output "$BIN_PATH"

cat > "$PLIST_PATH" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>Wing Multitrack Renamer</string>
  <key>CFBundleIdentifier</key>
  <string>com.aryeah86.wingsnapwavrenamer</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>Wing Multitrack Renamer</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

if [[ "$ENABLE_SIGNING" == "1" ]]; then
  codesign --remove-signature "$BIN_PATH" 2>/dev/null || true
  codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$BIN_PATH"
  codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$APP_DIR"
else
  codesign --force --deep --sign - "$APP_DIR"
fi

echo
echo "Built native app:"
echo "  $APP_DIR"
