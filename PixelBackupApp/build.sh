#!/usr/bin/env bash
# build.sh — Build PixelBackup.app from the Swift Package
# Usage:
#   ./build.sh              # debug build (fast, no signing)
#   ./build.sh --release    # release build, code-signed, notarized
#
# Prerequisites for release:
#   export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
#   export APPLE_ID="your@email.com"
#   export NOTARY_TEAM="TEAMID"
#   export NOTARY_PASSWORD="@keychain:AC_PASSWORD"   # or plain password
#   brew install create-dmg

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="PixelBackup"
BUNDLE_ID="com.pixelbackup.app"
BUILD_DIR="$SCRIPT_DIR/.build"
RELEASE_DIR="$SCRIPT_DIR/release"
APP_BUNDLE="$RELEASE_DIR/$APP_NAME.app"
ENTITLEMENTS="$SCRIPT_DIR/PixelBackup.entitlements"
INFOPLIST="$SCRIPT_DIR/Sources/PixelBackup/Info.plist"

RELEASE=0
if [[ "${1:-}" == "--release" ]]; then
    RELEASE=1
fi

# ─── Validate adb binary ────────────────────────────────────────────────────
ADB_RES="$SCRIPT_DIR/Sources/PixelBackup/Resources/adb"
if [[ ! -x "$ADB_RES" ]]; then
    echo "ERROR: adb binary not found at $ADB_RES"
    echo "Run: curl -L -o /tmp/pt.zip https://dl.google.com/android/repository/platform-tools-latest-darwin.zip"
    echo "     unzip -j /tmp/pt.zip platform-tools/adb -d Sources/PixelBackup/Resources/"
    echo "     chmod +x Sources/PixelBackup/Resources/adb"
    exit 1
fi

# ─── Build ───────────────────────────────────────────────────────────────────
echo "▶ Building $APP_NAME (release=$RELEASE)…"
mkdir -p "$RELEASE_DIR"

if [[ $RELEASE -eq 1 ]]; then
    swift build -c release --package-path "$SCRIPT_DIR"
    BINARY="$BUILD_DIR/release/$APP_NAME"
else
    swift build -c debug --package-path "$SCRIPT_DIR"
    BINARY="$BUILD_DIR/debug/$APP_NAME"
fi

if [[ ! -f "$BINARY" ]]; then
    echo "ERROR: Build produced no binary at $BINARY"
    exit 1
fi

# ─── Assemble .app bundle ────────────────────────────────────────────────────
echo "▶ Assembling $APP_NAME.app bundle…"
rm -rf "$APP_BUNDLE"
CONTENTS="$APP_BUNDLE/Contents"
mkdir -p "$CONTENTS/MacOS"
mkdir -p "$CONTENTS/Resources"

cp "$BINARY" "$CONTENTS/MacOS/$APP_NAME"
cp "$INFOPLIST" "$CONTENTS/Info.plist"

# Copy bundled resources (adb + pixel_backup.sh)
BUILT_RESOURCES="$BUILD_DIR/$([ $RELEASE -eq 1 ] && echo release || echo debug)/PixelBackup_PixelBackup.bundle/Contents/Resources"
if [[ -d "$BUILT_RESOURCES" ]]; then
    cp -r "$BUILT_RESOURCES/"* "$CONTENTS/Resources/"
else
    # Fallback: copy directly from source
    cp "$ADB_RES" "$CONTENTS/Resources/adb"
    cp "$SCRIPT_DIR/Sources/PixelBackup/Resources/pixel_backup.sh" "$CONTENTS/Resources/pixel_backup.sh"
fi

chmod +x "$CONTENTS/Resources/adb"
chmod +x "$CONTENTS/Resources/pixel_backup.sh"

# App icon — must sit directly in Contents/Resources/ for CFBundleIconFile to resolve
ICON_SRC="$SCRIPT_DIR/Sources/PixelBackup/Resources/AppIcon.icns"
if [[ -f "$ICON_SRC" ]]; then
    cp "$ICON_SRC" "$CONTENTS/Resources/AppIcon.icns"
fi

# ─── Code sign ───────────────────────────────────────────────────────────────
if [[ $RELEASE -eq 1 ]]; then
    if [[ -z "${DEVELOPER_ID:-}" ]]; then
        echo "ERROR: Set DEVELOPER_ID env var for release signing."
        echo "  export DEVELOPER_ID=\"Developer ID Application: Your Name (TEAMID)\""
        exit 1
    fi

    echo "▶ Signing bundled adb…"
    codesign --force --options runtime \
             --entitlements "$ENTITLEMENTS" \
             --sign "$DEVELOPER_ID" \
             "$CONTENTS/Resources/adb"

    echo "▶ Signing $APP_NAME.app…"
    codesign --force --options runtime --deep \
             --entitlements "$ENTITLEMENTS" \
             --sign "$DEVELOPER_ID" \
             "$APP_BUNDLE"

    echo "▶ Verifying signature…"
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
    spctl --assess --type execute --verbose "$APP_BUNDLE" || true
else
    echo "▶ Ad-hoc signing (debug)…"
    codesign --force --deep --sign - \
             --entitlements "$ENTITLEMENTS" \
             "$APP_BUNDLE"
fi

echo "✅ App bundle: $APP_BUNDLE"

# ─── Install to /Applications ────────────────────────────────────────────────
INSTALL_DEST="/Applications/$APP_NAME.app"
echo "▶ Installing to $INSTALL_DEST…"
rm -rf "$INSTALL_DEST"
cp -r "$APP_BUNDLE" /Applications/
touch "$INSTALL_DEST"           # nudge Finder to refresh the icon
echo "✅ Installed: $INSTALL_DEST"

# ─── DMG (release only) ──────────────────────────────────────────────────────
if [[ $RELEASE -eq 1 ]]; then
    if ! command -v create-dmg &>/dev/null; then
        echo "⚠ create-dmg not found; skipping DMG. Install: brew install create-dmg"
    else
        echo "▶ Creating DMG…"
        DMG_PATH="$RELEASE_DIR/${APP_NAME}.dmg"
        rm -f "$DMG_PATH"
        create-dmg \
            --volname "$APP_NAME" \
            --volicon "$SCRIPT_DIR/Sources/PixelBackup/Resources/AppIcon.icns" \
            --window-pos 200 120 \
            --window-size 660 400 \
            --icon-size 128 \
            --icon "$APP_NAME.app" 160 175 \
            --hide-extension "$APP_NAME.app" \
            --app-drop-link 500 175 \
            "$DMG_PATH" \
            "$APP_BUNDLE" || true
        echo "✅ DMG: $DMG_PATH"
    fi
fi

echo ""
echo "─── Done ───────────────────────────────────────────────────────────────────"
echo "   App: $INSTALL_DEST"
echo "   Run: open \"$INSTALL_DEST\""
