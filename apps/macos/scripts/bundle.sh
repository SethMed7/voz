#!/bin/sh
# Builds voz.app from the SwiftPM executable — no Xcode project needed.
set -e
cd "$(dirname "$0")/.."

swift build -c release

APP="build/voz.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/voz "$APP/Contents/MacOS/voz"
cp Info.plist "$APP/Contents/Info.plist"

# SwiftPM resource bundles (e.g. voz_Shared.bundle — the brand SVGs loaded via Bundle.module).
# Bundle.module resolves these from the app's Resources dir, so copy any that the build emitted.
for b in .build/release/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done

# Strip the debug symbol map — it embeds absolute build paths like
# /Users/<you>/voz/.build/.../*.swift.o, which would otherwise leak your macOS
# username into the public binary. Must run before codesign (it edits the binary).
strip -S "$APP/Contents/MacOS/voz"

# Bundle the setup + bootstrap scripts so a DOWNLOADED app can install the optional engines
# itself (menu → "Set up better engines…"). They're sealed by the signature below.
mkdir -p "$APP/Contents/Resources/scripts"
cp scripts/bootstrap.sh scripts/setup-*.sh "$APP/Contents/Resources/scripts/" 2>/dev/null || true
chmod +x "$APP/Contents/Resources/scripts/"*.sh 2>/dev/null || true

# App icon: media/icon.png (1024px) -> voz.icns, when present.
if [ -f media/icon.png ]; then
  ICONSET="build/voz.iconset"
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s media/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) media/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/voz.icns"
fi

# Sign with a STABLE identity so macOS keeps the Accessibility / Microphone grants
# across updates. An ad-hoc signature is content-hashed and changes every build,
# which silently invalidates the grants and re-prompts on every update.
# Order: explicit $VOZ_SIGN_ID -> self-signed "voz Code Signing" -> first valid
# codesigning identity -> ad-hoc (only if nothing else is available).
find_identity() {
  if [ -n "${VOZ_SIGN_ID:-}" ]; then printf '%s' "$VOZ_SIGN_ID"; return; fi
  if security find-identity -p codesigning 2>/dev/null | grep -q "voz Code Signing"; then
    printf '%s' "voz Code Signing"; return
  fi
  printf '%s' "$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"/{print $2; exit}')"
}
SIGN_ID=$(find_identity)
if [ -n "$SIGN_ID" ]; then
  echo "Signing with: $SIGN_ID"
  codesign --force --deep -s "$SIGN_ID" "$APP"
else
  echo "No signing identity found — using ad-hoc. Grants will reset on every update;"
  echo "run scripts/codesign-setup.sh once for a stable identity."
  codesign --force --deep -s - "$APP"
fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Built $APP ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"))"
