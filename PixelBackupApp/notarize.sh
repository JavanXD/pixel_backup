#!/usr/bin/env bash
# notarize.sh — Submit PixelBackup.app to Apple for notarization and staple.
#
# Run AFTER build.sh --release.
#
# Required environment variables:
#   APPLE_ID         your Apple ID email
#   NOTARY_TEAM      10-character Team ID (found in developer.apple.com → Membership)
#   NOTARY_PASSWORD  app-specific password OR @keychain:AC_PASSWORD
#                    (create one at appleid.apple.com → App-Specific Passwords)
#
# Example:
#   export APPLE_ID="you@example.com"
#   export NOTARY_TEAM="ABCDE12345"
#   export NOTARY_PASSWORD="@keychain:AC_PASSWORD"
#   ./notarize.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="PixelBackup"
RELEASE_DIR="$SCRIPT_DIR/release"
APP_BUNDLE="$RELEASE_DIR/$APP_NAME.app"
ZIP_PATH="$RELEASE_DIR/${APP_NAME}-notarize.zip"

: "${APPLE_ID:?Set APPLE_ID env var}"
: "${NOTARY_TEAM:?Set NOTARY_TEAM env var}"
: "${NOTARY_PASSWORD:?Set NOTARY_PASSWORD env var}"

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "ERROR: $APP_BUNDLE not found. Run ./build.sh --release first."
    exit 1
fi

echo "▶ Zipping app for notarization…"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "▶ Submitting to Apple notary service…"
xcrun notarytool submit "$ZIP_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$NOTARY_TEAM" \
    --password "$NOTARY_PASSWORD" \
    --wait

echo "▶ Stapling notarization ticket to app…"
xcrun stapler staple "$APP_BUNDLE"

echo "▶ Verifying Gatekeeper acceptance…"
spctl --assess --type execute --verbose "$APP_BUNDLE"

rm -f "$ZIP_PATH"
echo "✅ Notarization complete. $APP_BUNDLE is ready to distribute."
