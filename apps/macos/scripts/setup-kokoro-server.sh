#!/bin/sh
# voz's WARM read-aloud engine: keeps Kokoro loaded in a tiny local bun server so each selection
# reads with a consistent ~0.3-0.6s first audio instead of the ~1-2s per-spawn model reload the
# one-shot say.ts pays — SAME model + voices, nothing re-downloaded. 100% on-device, binds 127.0.0.1
# only. Installs core/say-server.ts beside the kokoro-js helper that setup-kokoro.sh already set up.
# Run in-place by the app's "Set up better engines…"; not meant to be run standalone.
set -e

# Resolve the helper dir kokoro-js is installed in (matches KokoroEngine/WarmTTS): ~/.voz/kokoro else ~/.leelo.
DIR=""
for d in "$HOME/.voz/kokoro" "$HOME/.leelo"; do
  if [ -d "$d/node_modules/kokoro-js" ]; then DIR="$d"; break; fi
done
[ -n "$DIR" ] || { echo "Kokoro voices aren't installed. Run setup-kokoro.sh first, then re-run this."; exit 1; }
command -v bun >/dev/null 2>&1 || [ -x "$HOME/.bun/bin/bun" ] \
  || { echo "bun not found — run setup-kokoro.sh first (it installs bun + the voices)."; exit 1; }

HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
if [ -n "$HERE" ] && [ -f "$HERE/../../../core/say-server.ts" ]; then
  cp "$HERE/../../../core/say-server.ts" "$DIR/"
else
  curl -fsSL https://raw.githubusercontent.com/SethMed7/voz/main/core/say-server.ts -o "$DIR/say-server.ts"
fi

echo
echo "Warm read-aloud installed to $DIR. voz keeps Kokoro loaded → consistent ~0.3-0.6s first audio."
echo "It starts on your next read (and is reused across restarts). Toggle read-aloud off/on to start it now."
