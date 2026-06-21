#!/bin/sh
# voz's OPTIONAL on-device AI polish for dictation: real punctuation + contextual filler removal
# ("like", "right", "you know"), 100% on-device — no cloud, no API key, NO Ollama. voz provisions its
# OWN engine: a small open-weight model (Qwen2.5-1.5B-Instruct, Apache-2.0) run via MLX (Apple's Metal
# framework) and kept warm in a tiny loopback server — the same warm-server pattern voz uses for
# Parakeet dictation. Apple Silicon only; Intel Macs fall back to a self-contained llama.cpp. The model
# is PINNED (everyone gets the same cleanup) and downloaded only with your consent.
# Run in-place by the app's "Set up better engines…"; not meant to be run standalone.
set -e

DIR="$HOME/.voz"
MODEL_ID="${VOZ_LLM_MODEL:-mlx-community/Qwen2.5-1.5B-Instruct-4bit}"
mkdir -p "$DIR"

# ── Preferred (Apple Silicon): voz's own warm MLX server ───────────────────────
if [ "$(uname -m)" = arm64 ]; then
  VENV="$DIR/llm-venv"
  command -v python3 >/dev/null 2>&1 || {
    echo "python3 not found — install the Xcode Command Line Tools first:  xcode-select --install"
    exit 1
  }

  [ -d "$VENV" ] || python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q --upgrade pip >/dev/null 2>&1 || true
  echo "Installing mlx-lm into the venv (one time)…"
  "$VENV/bin/pip" install -q mlx-lm

  # Install the warm server (from the checkout, else fetch the pinned copy).
  HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
  if [ -n "$HERE" ] && [ -f "$HERE/../../../core/llm-server.py" ]; then
    cp "$HERE/../../../core/llm-server.py" "$DIR/"
  else
    curl -fsSL https://raw.githubusercontent.com/SethMed7/voz/main/core/llm-server.py -o "$DIR/llm-server.py"
  fi

  # Download the pinned model with consent (into the shared Hugging Face cache; ~0.9 GB). The marker
  # file at ~/.voz/llm-model is what flips voz's warm path on — the server runs offline, so it only
  # starts once weights are actually cached.
  if [ -f "$DIR/llm-model" ]; then
    echo "Cleanup model already downloaded ($MODEL_ID)."
  else
    printf 'Download the Qwen2.5-1.5B-Instruct cleanup model (~0.9 GB, Apache-2.0)? [y/N] '
    read -r ans 2>/dev/null || ans=""
    case "$ans" in
      [Yy]*)
        echo "Downloading $MODEL_ID … (first run only)"
        if "$VENV/bin/python" - "$MODEL_ID" <<'PY'
import sys
from mlx_lm import load
load(sys.argv[1])  # downloads to the HF cache, then verifies it loads under this mlx-lm
PY
        then
          printf '%s\n' "$MODEL_ID" > "$DIR/llm-model"
          echo
          echo "On-device AI cleanup installed (menu → Dictate → 'Polish with AI')."
        else
          echo "Download/verify failed — voz keeps using the deterministic cleaner."
          exit 1
        fi
        ;;
      *) echo "Skipped — voz keeps using the deterministic cleaner."; exit 0 ;;
    esac
  fi
  exit 0
fi

# ── Fallback (Intel Macs, no MLX): a self-contained llama.cpp + small open-weight model ────────────
echo "MLX needs Apple Silicon — on this Intel Mac voz uses a self-contained llama.cpp + model instead."
LLM="$DIR/llm"; BIN="$LLM/bin"; mkdir -p "$BIN"
ARCH="macos-x64"

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

MODEL="$LLM/model.gguf"
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
