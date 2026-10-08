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

# Locate the SPM resource bundle. Layout is a flat bundle
# (…/PixelBackup_PixelBackup.bundle/Resources/…), not Contents/Resources.
CONFIG=$([ $RELEASE -eq 1 ] && echo release || echo debug)
SPM_BUNDLE=""
for candidate in \
    "$BUILD_DIR/$CONFIG/PixelBackup_PixelBackup.bundle" \
    "$BUILD_DIR/arm64-apple-macosx/$CONFIG/PixelBackup_PixelBackup.bundle" \
    "$BUILD_DIR/x86_64-apple-macosx/$CONFIG/PixelBackup_PixelBackup.bundle"
do
    if [[ -d "$candidate" ]]; then
        SPM_BUNDLE="$candidate"
        break
    fi
done

# Embed the SPM bundle so localizations + AppResources can resolve it.
if [[ -n "$SPM_BUNDLE" ]]; then
    cp -R "$SPM_BUNDLE" "$CONTENTS/Resources/PixelBackup_PixelBackup.bundle"
fi

# Also flatten runtime binaries into Contents/Resources for Bundle.main fallback
# and for a stable codesign path.
copy_runtime_resource() {
    local name="$1"
    local dest="$CONTENTS/Resources/$name"
    for src in \
        "$CONTENTS/Resources/PixelBackup_PixelBackup.bundle/Resources/$name" \
        "$CONTENTS/Resources/PixelBackup_PixelBackup.bundle/Contents/Resources/$name" \
        "$CONTENTS/Resources/PixelBackup_PixelBackup.bundle/Contents/Resources/Resources/$name" \
        "$SCRIPT_DIR/Sources/PixelBackup/Resources/$name"
    do
        if [[ -f "$src" ]]; then
            cp "$src" "$dest"
            return 0
        fi
    done
    return 1
}

copy_runtime_resource "adb" || { echo "ERROR: adb missing from build resources"; exit 1; }
copy_runtime_resource "pixel_backup.sh" || { echo "ERROR: pixel_backup.sh missing"; exit 1; }

chmod +x "$CONTENTS/Resources/adb"
chmod +x "$CONTENTS/Resources/pixel_backup.sh"
# Keep the copy inside the SPM bundle executable too, when present.
find "$CONTENTS/Resources/PixelBackup_PixelBackup.bundle" -name adb -type f -exec chmod +x {} \; 2>/dev/null || true
find "$CONTENTS/Resources/PixelBackup_PixelBackup.bundle" -name 'pixel_backup.sh' -type f -exec chmod +x {} \; 2>/dev/null || true

# App icon — must sit directly in Contents/Resources/ for CFBundleIconFile to resolve
ICON_SRC="$SCRIPT_DIR/Sources/PixelBackup/Resources/AppIcon.icns"
if [[ -f "$ICON_SRC" ]]; then
    cp "$ICON_SRC" "$CONTENTS/Resources/AppIcon.icns"
fi

# Privacy manifest (required by Apple for UserDefaults / filesystem / network APIs)
PRIVACY_SRC="$SCRIPT_DIR/Sources/PixelBackup/Resources/PrivacyInfo.xcprivacy"
if [[ -f "$PRIVACY_SRC" ]]; then
    cp "$PRIVACY_SRC" "$CONTENTS/Resources/PrivacyInfo.xcprivacy"
fi

# Localizations at Resources root so Bundle.main can resolve them too
if [[ -n "$SPM_BUNDLE" ]]; then
    for lproj in "$SPM_BUNDLE"/*.lproj; do
        [[ -d "$lproj" ]] || continue
        cp -R "$lproj" "$CONTENTS/Resources/"
    done
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
    # Sign any nested adb copies inside the SPM resource bundle.
    while IFS= read -r nested_adb; do
        codesign --force --options runtime \
                 --entitlements "$ENTITLEMENTS" \
                 --sign "$DEVELOPER_ID" \
                 "$nested_adb"
    done < <(find "$CONTENTS/Resources/PixelBackup_PixelBackup.bundle" -name adb -type f 2>/dev/null || true)

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
echo "▶ Installing to ${INSTALL_DEST}…"
rm -rf "$INSTALL_DEST"
cp -R "$APP_BUNDLE" /Applications/
touch "$INSTALL_DEST"           # nudge Finder to refresh the icon
echo "✅ Installed: ${INSTALL_DEST}"

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
