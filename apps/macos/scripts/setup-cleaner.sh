#!/bin/sh
# voz's OPTIONAL on-device AI polish for dictation: real punctuation + contextual filler
# removal ("like", "right", "you know"), 100% on-device — no cloud, no API key. It REUSES a
# local LLM runtime you already run, preferring an existing Ollama (the same one tools like
# Breve use) so nothing is installed twice. Only if you have no Ollama does it fall back to a
# self-contained llama.cpp + small model. Works from a checkout OR standalone:
#   curl -fsSL https://raw.githubusercontent.com/SethMed7/voz/main/apps/macos/scripts/setup-cleaner.sh | sh
set -e

OLLAMA="${OLLAMA_HOST:-127.0.0.1:11434}"
case "$OLLAMA" in *://*) ;; *) OLLAMA="http://$OLLAMA" ;; esac

# --- Preferred: reuse an Ollama you already run (no new install) ---
if command -v ollama >/dev/null 2>&1 || curl -s --max-time 2 "$OLLAMA/api/tags" >/dev/null 2>&1; then
  if curl -s --max-time 3 "$OLLAMA/api/tags" 2>/dev/null | grep -q '"name"'; then
    echo "Found a running Ollama with a model — voz uses it automatically."
    echo "  • Toggle: menu → Dictate → 'Polish with AI'."
    echo "  • A thinking model (e.g. gemma) is auto-run with thinking OFF, so it's fast (~1s)."
    echo "  • Pin a specific model with:  export VOZ_OLLAMA_MODEL=<name>   (e.g. a small qwen2.5:1.5b)."
    exit 0
  fi
  echo "Ollama is installed but has no models. Pull a small one voz can use:"
  printf 'Pull qwen2.5:1.5b now (~1 GB, Apache-2.0)? [y/N] '
  read -r ans 2>/dev/null || ans=""
  case "$ans" in
    [Yy]*) ollama pull qwen2.5:1.5b && echo "Done — voz will use it automatically." ; exit 0 ;;
    *) echo "Skipped — voz uses the deterministic cleaner until a model is available."; exit 0 ;;
  esac
fi

# --- Fallback (no Ollama): a self-contained llama.cpp + small open-weight model ---
echo "No Ollama found — installing a self-contained llama.cpp + model instead."
DIR="$HOME/.voz/llm"; BIN="$DIR/bin"; mkdir -p "$BIN"
case "$(uname -m)" in arm64) ARCH="macos-arm64" ;; *) ARCH="macos-x64" ;; esac

have_llama() {
  command -v llama-cli >/dev/null 2>&1 || [ -x "$BIN/llama-cli" ] \
    || [ -x /opt/homebrew/bin/llama-cli ] || [ -x /usr/local/bin/llama-cli ]
}
if have_llama; then
  echo "llama.cpp already present — using it."
elif command -v brew >/dev/null 2>&1; then
  echo "Installing llama.cpp via Homebrew…"
  brew install llama.cpp
else
  echo "Downloading llama.cpp ($ARCH) from GitHub releases…"
  URL="$(curl -fsSL https://api.github.com/repos/ggml-org/llama.cpp/releases/latest \
    | grep -o 'https://[^"]*bin-'"$ARCH"'\.zip' | head -n1)"
  [ -n "$URL" ] || { echo "Couldn't resolve a llama.cpp $ARCH asset. Install manually: brew install llama.cpp"; exit 1; }
  TMP="$(mktemp -d)"; curl -fL "$URL" -o "$TMP/llama.zip"; unzip -oq "$TMP/llama.zip" -d "$TMP"
  SRC="$(dirname "$(find "$TMP" -name llama-cli -type f | head -n1)")"
  [ -n "$SRC" ] || { echo "llama-cli not found in the release zip."; exit 1; }
  cp "$SRC"/* "$BIN"/ 2>/dev/null || true; chmod +x "$BIN"/llama-* 2>/dev/null || true; rm -rf "$TMP"
  echo "llama.cpp installed to $BIN."
fi

MODEL="$DIR/model.gguf"
MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf?download=true"
if [ -f "$MODEL" ]; then
  echo "Model already present at $MODEL."
else
  printf 'Download the Qwen2.5-1.5B-Instruct cleanup model (Apache-2.0, ~1.0 GB)? [y/N] '
  read -r ans 2>/dev/null || ans=""
  case "$ans" in
    [Yy]*) echo "Downloading model…"; curl -fL "$MODEL_URL" -o "$MODEL" ;;
    *) echo "Skipped — voz keeps using the deterministic cleaner."; exit 0 ;;
  esac
fi
echo
[ -f "$MODEL" ] && have_llama && echo "On-device AI cleanup installed (menu → Dictate → 'Polish with AI')." \
  || echo "Setup incomplete — voz falls back to the deterministic cleaner."
