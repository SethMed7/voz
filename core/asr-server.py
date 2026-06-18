#!/usr/bin/env python3
"""voz's warm ASR server — loads NVIDIA Parakeet (sherpa-onnx) ONCE and serves transcription over
local HTTP, so dictation is never slowed by the per-clip model reload (~1.5s) that the one-shot CLI
pays. Warm decodes are ~0.05s. 100% on-device; binds 127.0.0.1 ONLY. Reuses the model already on
disk — nothing is re-downloaded. Installed + run by scripts/setup-asr.sh (a venv with sherpa-onnx).

Protocol (loopback, same machine, so we pass a file path — no upload):
  GET  /health                       -> 200 {"ok": true}
  POST /transcribe  {"path": "/abs/16k-mono.wav"}  -> 200 {"text": "..."}
"""
import os, sys, json, wave, time, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
import numpy as np
import sherpa_onnx


def env(*names, default=""):
    for n in names:
        v = os.environ.get(n)
        if v:
            return v
    return default


MODEL = env("VOZ_PARAKEET_MODEL", "DICTADO_PARAKEET_MODEL",
            default=os.path.expanduser("~/.cache/sherpa/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"))
PORT = int(env("VOZ_ASR_PORT", default="8765"))
THREADS = int(env("VOZ_ASR_THREADS", default="4"))

recognizer = sherpa_onnx.OfflineRecognizer.from_transducer(
    tokens=f"{MODEL}/tokens.txt",
    encoder=f"{MODEL}/encoder.int8.onnx",
    decoder=f"{MODEL}/decoder.int8.onnx",
    joiner=f"{MODEL}/joiner.int8.onnx",
    num_threads=THREADS,
    decoding_method="greedy_search",
    model_type="nemo_transducer",
)


# Reclaim memory when unused: exit after a stretch with no requests (the app re-warms on the next
# dictation). Also reclaims an orphaned server left behind by a crash/force-quit.
IDLE = float(env("VOZ_ASR_IDLE_S", default="300"))
_last = [time.time()]


def _idle_watch():
    while True:
        time.sleep(30)
        if time.time() - _last[0] > IDLE:
            os._exit(0)


threading.Thread(target=_idle_watch, daemon=True).start()


def transcribe(path):
    w = wave.open(path, "rb")
    sr = w.getframerate()
    ch = w.getnchannels()
    raw = w.readframes(w.getnframes())
    w.close()
    a = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    if ch == 2:
        a = a.reshape(-1, 2).mean(axis=1)
    s = recognizer.create_stream()
    s.accept_waveform(sr, a)
    recognizer.decode_stream(s)
    return s.result.text


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass  # quiet — no transcript or request logging

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        _last[0] = time.time()
        self._send(200, {"ok": True}) if self.path == "/health" else self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/transcribe":
            return self._send(404, {"error": "not found"})
        _last[0] = time.time()
        try:
            n = int(self.headers.get("Content-Length", 0))
            path = json.loads(self.rfile.read(n)).get("path", "")
            if not path or not os.path.exists(path):
                return self._send(400, {"error": "bad path"})
            self._send(200, {"text": transcribe(path)})
        except Exception as e:  # never crash the warm server on a bad request
            self._send(500, {"error": str(e)})


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
