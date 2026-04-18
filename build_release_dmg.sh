#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Wing Multitrack Renamer"
VOL_NAME="$APP_NAME"
DIST_DIR="$ROOT_DIR/dist-release"
APP_PATH="$ROOT_DIR/dist-native/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
TMP_DMG="$DIST_DIR/$APP_NAME-temp.dmg"
STAGE_DIR="$DIST_DIR/dmg-stage"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Lev Aranovich (SX22W5X23G)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AC_NOTARY}"
WINDOW_BOUNDS="${WINDOW_BOUNDS:-{120, 120, 780, 520}}"

cleanup() {
  if mount | grep -q "/Volumes/$VOL_NAME"; then
    hdiutil detach "/Volumes/$VOL_NAME" -quiet || true
  fi
}
trap cleanup EXIT

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR" "$STAGE_DIR"

"$ROOT_DIR/build_native_macos_app.sh"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Missing built app at $APP_PATH" >&2
  exit 1
fi

APP_BIN="$APP_PATH/Contents/MacOS/$APP_NAME"
APP_ARCHS="$(lipo -archs "$APP_BIN")"
echo "Universal binary architectures: $APP_ARCHS"

ditto "$APP_PATH" "$STAGE_DIR/$APP_NAME.app"
ln -s /Applications "$STAGE_DIR/Applications"

hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGE_DIR" \
  -format UDRW \
  -fs HFS+ \
  "$TMP_DMG" \
  >/dev/null

hdiutil attach "$TMP_DMG" -readwrite -noverify -noautoopen >/dev/null

osascript <<OSA
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    tell container window
      set current view to icon view
      set toolbar visible to false
      set statusbar visible to false
      set bounds to $WINDOW_BOUNDS
    end tell
    tell icon view options of container window
      set arrangement to not arranged
      set icon size to 128
      set text size to 14
    end tell
    set position of item "$APP_NAME.app" of container window to {180, 190}
    set position of item "Applications" of container window to {500, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA

hdiutil detach "/Volumes/$VOL_NAME" -quiet

hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
rm -f "$TMP_DMG"

codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"

NOTARY_JSON="$(xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"
echo "$NOTARY_JSON" > "$DIST_DIR/notary-result.json"
echo "$NOTARY_JSON"

xcrun stapler staple "$DMG_PATH"

echo
echo "Validation:"
codesign --verify --verbose=2 "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl -a -vv -t open "$DMG_PATH" || true

echo
echo "Release artifacts:"
echo "  App: $APP_PATH"
echo "  DMG: $DMG_PATH"
