#!/bin/sh
# Installs voz's canonical cleanup helper (pure Bun TypeScript, fully on-device)
# to ~/.voz. Without it, voz uses the built-in Swift cleaner. Requires bun
# (https://bun.sh). Works from a repo checkout OR standalone:
#   curl -fsSL https://raw.githubusercontent.com/SethMed7/voz/main/apps/macos/scripts/setup-helper.sh | sh
set -e
DIR="$HOME/.voz"
LEGACY="$HOME/.dictado"
RAW="https://raw.githubusercontent.com/SethMed7/voz/main/core"
command -v bun >/dev/null 2>&1 || { echo "bun not found — install from https://bun.sh first"; exit 1; }
mkdir -p "$DIR"

HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
if [ -n "$HERE" ] && [ -f "$HERE/../../../core/clean.ts" ]; then
  cp "$HERE/../../../core/clean.ts" "$DIR/"
else
  curl -fsSL "$RAW/clean.ts" -o "$DIR/clean.ts"
fi

# Carry a learned dictionary forward from the legacy ~/.dictado (non-destructive copy).
if [ -f "$LEGACY/dictionary.json" ] && [ ! -f "$DIR/dictionary.json" ]; then
  cp "$LEGACY/dictionary.json" "$DIR/dictionary.json"
  echo "Migrated your dictionary from ~/.dictado → ~/.voz/dictionary.json."
fi
echo
echo "Cleanup helper installed to ~/.voz (no dependencies, nothing to download)."

# --- Optional: the Parakeet engine (best accuracy, non-OpenAI, no silence noise) ---
# voz works out of the box on Apple's on-device recognizer. Installing NVIDIA
# Parakeet (CC-BY-4.0) via the sherpa-onnx binary upgrades accuracy and removes any
# length cap — fully on-device, nothing from OpenAI. ~25MB binary + ~482MB model.
# Lives in the shared ~/.cache/sherpa; skipped silently when piped (no TTY) or if you decline.
SHERPA_DIR="$HOME/.cache/sherpa"
SHERPA_VER="v1.13.2"
have_parakeet() { ls "$SHERPA_DIR"/*/bin/sherpa-onnx-offline >/dev/null 2>&1 && ls "$SHERPA_DIR"/*parakeet*/encoder.int8.onnx >/dev/null 2>&1; }
if ! have_parakeet; then
  printf 'Install the Parakeet engine (NVIDIA, best accuracy, non-OpenAI)? [y/N] '
  read -r ans 2>/dev/null || ans=""
  case "$ans" in
    [Yy]*)
      mkdir -p "$SHERPA_DIR"
      case "$(uname -m)" in arm64) ARCH="osx-arm64" ;; *) ARCH="osx-x64" ;; esac
      REL="https://github.com/k2-fsa/sherpa-onnx/releases/download"
      if ! ls "$SHERPA_DIR"/*/bin/sherpa-onnx-offline >/dev/null 2>&1; then
        echo "Downloading sherpa-onnx $SHERPA_VER ($ARCH, ~25MB)…"
        curl -fL "$REL/$SHERPA_VER/sherpa-onnx-$SHERPA_VER-$ARCH-shared.tar.bz2" -o "$SHERPA_DIR/sherpa-bin.tar.bz2" \
          && tar xjf "$SHERPA_DIR/sherpa-bin.tar.bz2" -C "$SHERPA_DIR" && rm -f "$SHERPA_DIR/sherpa-bin.tar.bz2"
      fi
      if ! ls "$SHERPA_DIR"/*parakeet*/encoder.int8.onnx >/dev/null 2>&1; then
        echo "Downloading Parakeet TDT 0.6B model (~482MB)…"
        curl -fL "$REL/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2" -o "$SHERPA_DIR/parakeet.tar.bz2" \
          && tar xjf "$SHERPA_DIR/parakeet.tar.bz2" -C "$SHERPA_DIR" && rm -f "$SHERPA_DIR/parakeet.tar.bz2"
      fi
      have_parakeet && echo "Parakeet installed → voz will use it automatically." \
        || echo "Install incomplete — voz falls back to Apple's on-device recognizer."
      ;;
    *) echo "Skipped Parakeet — voz uses Apple's on-device recognizer until you add it." ;;
  esac
fi
