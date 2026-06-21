#!/bin/sh
# voz's WARM ASR engine: keeps NVIDIA Parakeet loaded in a tiny local server so each dictation
# transcribes in ~0.08s instead of the ~1.5s a cold CLI spawn costs — SAME model, same quality,
# nothing re-downloaded. 100% on-device, binds 127.0.0.1 only. Creates a venv with sherpa-onnx and
# installs core/asr-server.py to ~/.voz.
# Run in-place by the app's "Set up better engines…"; not meant to be run standalone.
set -e
DIR="$HOME/.voz"; VENV="$DIR/asr-venv"
mkdir -p "$DIR"
command -v python3 >/dev/null 2>&1 || { echo "python3 not found — install it (e.g. via Xcode CLT or Homebrew) first."; exit 1; }

# The Parakeet model must already be installed (by setup-helper.sh). We reuse it — no re-download.
ls "$HOME/.cache/sherpa/"*parakeet*/encoder.int8.onnx >/dev/null 2>&1 \
  || { echo "Parakeet model not found. Run setup-helper.sh first to install it, then re-run this."; exit 1; }

[ -d "$VENV" ] || python3 -m venv "$VENV"
"$VENV/bin/pip" install -q --upgrade pip >/dev/null 2>&1 || true
echo "Installing sherpa-onnx + numpy into the venv (one time)…"
"$VENV/bin/pip" install -q sherpa-onnx numpy

HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
if [ -n "$HERE" ] && [ -f "$HERE/../../../core/asr-server.py" ]; then
  cp "$HERE/../../../core/asr-server.py" "$DIR/"
else
  curl -fsSL https://raw.githubusercontent.com/SethMed7/voz/main/core/asr-server.py -o "$DIR/asr-server.py"
fi

echo
echo "Warm ASR installed. voz keeps Parakeet loaded → near-instant transcription (~0.08s)."
echo "It starts on your next dictation (and is reused across restarts). Toggle dictation off/on to (re)start it now."
