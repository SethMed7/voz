#!/bin/sh
# Builds a DISTRIBUTABLE, notarized voz.dmg — the thing people download and double-click.
#
# Requires (one-time): a "Developer ID Application" cert in your Keychain, and notarization creds
# stored under a profile (default: voz-notary) via:
#   xcrun notarytool store-credentials voz-notary --apple-id <id> --team-id <team> --password <app-specific-pw>
#
# No secrets live in this repo — the cert's private key + the notary password stay in your Keychain.
set -e
cd "$(dirname "$0")/.."

PROFILE="${VOZ_NOTARY_PROFILE:-voz-notary}"
DEVID=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')
if [ -z "$DEVID" ]; then
  echo "✗ No 'Developer ID Application' certificate in your Keychain."
  echo "  Create one: Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application."
  exit 1
fi
echo "Signing identity: $DEVID"
APP="build/voz.app"

# 1. Assemble the .app (build + icon + strip), signed with the Developer ID cert.
VOZ_SIGN_ID="$DEVID" sh scripts/bundle.sh

# 2. Re-sign with the HARDENED RUNTIME + secure timestamp + entitlements (notarization requires all three).
codesign --force --options runtime --timestamp --entitlements voz.entitlements -s "$DEVID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
mkdir -p dist

# 3. Notarize the app (Apple scans it, then we staple the ticket so it works offline).
ZIP="dist/voz-$VER.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "→ Notarizing the app (Apple, ~1–3 min)…"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"

# 4. Build a drag-to-install DMG (voz.app + an Applications shortcut).
DMG="dist/voz-$VER.dmg"
STAGE="build/dmg"; rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/voz.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "voz" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

# 5. Sign, notarize, and staple the DMG itself.
codesign --force --timestamp -s "$DEVID" "$DMG"
echo "→ Notarizing the DMG…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo
echo "✓ Notarized, ready to ship: $DMG"
spctl -a -vv -t install "$DMG" 2>&1 || true
echo "Upload with:  gh release create v$VER \"$DMG\" --title \"voz $VER\" --notes \"…\""
