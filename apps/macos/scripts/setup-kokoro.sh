#!/bin/sh
# Installs voz's premium read-aloud voice (Kokoro, fully on-device) to ~/.voz/kokoro.
# Requires bun (https://bun.sh). Without it, voz uses the built-in macOS voice.
# Works from a repo checkout OR standalone:
#   curl -fsSL https://raw.githubusercontent.com/SethMed7/voz/main/apps/macos/scripts/setup-kokoro.sh | sh
set -e
DIR="$HOME/.voz/kokoro"
LEGACY="$HOME/.leelo"
RAW="https://raw.githubusercontent.com/SethMed7/voz/main/core"
command -v bun >/dev/null 2>&1 || { echo "bun not found — install from https://bun.sh first"; exit 1; }
mkdir -p "$HOME/.voz"

# Migrate an existing ~/.leelo install in place: symlink it so the ~80 MB Kokoro model
# and node_modules are never re-downloaded. The current say.ts is copied in below
# (it reads VOZ_VOICE, with LEELO_VOICE still honored), upgrading the linked install.
if [ ! -e "$DIR" ] && [ -d "$LEGACY/node_modules/kokoro-js" ]; then
  ln -s "$LEGACY" "$DIR"
  echo "Linked existing ~/.leelo install → ~/.voz/kokoro (no re-download)."
fi
mkdir -p "$DIR"

HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
if [ -n "$HERE" ] && [ -f "$HERE/../../../core/say.ts" ]; then
  cp "$HERE/../../../core/say.ts" "$HERE/../../../core/package.json" "$DIR/"
else
  curl -fsSL "$RAW/say.ts" -o "$DIR/say.ts"
  curl -fsSL "$RAW/package.json" -o "$DIR/package.json"
fi
cd "$DIR" && bun install
echo
echo "Kokoro voice installed to ~/.voz/kokoro. The first read downloads the model (~80 MB, one time)."
