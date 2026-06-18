/**
 * voz's WARM read-aloud server — loads Kokoro ONCE and serves renders over loopback HTTP, so each
 * selection skips the ~1-2s per-spawn model reload the one-shot say.ts pays. Warm first-audio is
 * ~0.3-0.6s and consistent. 100% on-device; binds 127.0.0.1 ONLY. Installed beside say.ts (reusing
 * its kokoro-js) by scripts/setup-kokoro-server.sh; run with bun. Started/managed by WarmTTS.swift.
 *
 * Protocol (loopback, same machine, so chunks are written to temp WAVs and only their PATHS are
 * streamed — no audio over the socket; identical "<path>\t<chunk>" lines say.ts prints):
 *   GET  /health                                   -> 200 {"ok": true}
 *   POST /render  {"text": "...", "voice": "af_heart"}
 *        -> streams one line per chunk as it's ready: "<wav path>\t<chunk text>\n"
 * Renders are SERIALIZED (one model, FIFO) so a prefetch can never fight the live read for CPU.
 */
import { mkdtempSync, writeFileSync, readdirSync, statSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const { env: hfEnv } = await import("@huggingface/transformers");
hfEnv.cacheDir = `${process.env.HOME}/.cache/huggingface-transformers`;
const { KokoroTTS } = await import("kokoro-js");

const PORT = Number(process.env.VOZ_TTS_PORT ?? 8766);

// --- chunking (identical to say.ts: a small first chunk → fast first audio, ~360 for the rest) ---
function splitFirstClause(s: string): [string, string] {
  const MIN = 24, MAX = 90;
  if (s.length <= MAX) return [s, ""];
  let cut = -1;
  const re = /[,;:.!?—]\s/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(s)) !== null) {
    const end = m.index + 1;
    if (end > MAX) break;
    if (end >= MIN) cut = end;
  }
  if (cut === -1) {
    const sp = s.lastIndexOf(" ", MAX);
    cut = sp >= MIN ? sp : MAX;
  }
  return [s.slice(0, cut).trim(), s.slice(cut).trim()];
}

function chunkText(input: string, max = 360): string[] {
  const norm = input.replace(/\s+/g, " ").trim();
  if (!norm) return [];
  const [head, rest] = splitFirstClause(norm);
  const chunks: string[] = head ? [head] : [];
  const sentences = rest.match(/[^.!?]+[.!?]+(\s|$)|[^.!?]+$/g) ?? (rest ? [rest] : []);
  let cur = "";
  for (const s of sentences) {
    if (cur && cur.length + s.length > max) { chunks.push(cur.trim()); cur = ""; }
    cur += s;
  }
  if (cur.trim()) chunks.push(cur.trim());
  return chunks;
}

function toWav(samples: Float32Array, sr: number): Buffer {
  const data = Buffer.alloc(44 + samples.length * 2);
  data.write("RIFF", 0);
  data.writeUInt32LE(36 + samples.length * 2, 4);
  data.write("WAVE", 8);
  data.write("fmt ", 12);
  data.writeUInt32LE(16, 16);
  data.writeUInt16LE(1, 20);
  data.writeUInt16LE(1, 22);
  data.writeUInt32LE(sr, 24);
  data.writeUInt32LE(sr * 2, 28);
  data.writeUInt16LE(2, 32);
  data.writeUInt16LE(16, 34);
  data.write("data", 36);
  data.writeUInt32LE(samples.length * 2, 40);
  for (let i = 0; i < samples.length; i++) {
    const s = Math.max(-1, Math.min(1, samples[i]));
    data.writeInt16LE(Math.round(s * 32767), 44 + i * 2);
  }
  return data;
}

const tts = await KokoroTTS.from_pretrained("onnx-community/Kokoro-82M-v1.0-ONNX", {
  dtype: "q8",
  device: "cpu",
});
await tts.generate("voz", { voice: "af_heart" as any }).catch(() => {}); // warm the ONNX session once

// Reclaim memory when unused: exit after a stretch with no requests (the app re-warms on the next
// read). Also fixes orphaned servers left behind by a crash/force-quit and the ~550MB idle footprint.
const IDLE_MS = Number(process.env.VOZ_TTS_IDLE_MS ?? 5 * 60 * 1000);
let lastActivity = Date.now();

// We hand out chunk-WAV paths and the client deletes the files after playing; the parent temp dir is
// left behind, so sweep dirs older than the playout window instead of accumulating them forever.
function sweepStaleTemp() {
  try {
    const base = tmpdir();
    for (const name of readdirSync(base)) {
      if (!name.startsWith("voz-") && !name.startsWith("leelo-")) continue;
      const p = join(base, name);
      try { if (Date.now() - statSync(p).mtimeMs > 2 * 60 * 1000) rmSync(p, { recursive: true, force: true }); } catch {}
    }
  } catch {}
}
sweepStaleTemp();
setInterval(() => {
  sweepStaleTemp();
  if (Date.now() - lastActivity > IDLE_MS) process.exit(0);
}, 30_000).unref?.();

// One model instance → renders must not overlap. Chain them so a prefetch waits behind the live read.
let tail: Promise<unknown> = Promise.resolve();
function serialize<T>(fn: () => Promise<T>): Promise<T> {
  const run = tail.then(fn, fn);
  tail = run.catch(() => {});
  return run;
}

const enc = new TextEncoder();

Bun.serve({
  port: PORT,
  hostname: "127.0.0.1",
  idleTimeout: 0, // a prefetch connection may wait in the FIFO, and long reads take a while
  async fetch(req) {
    lastActivity = Date.now();
    const url = new URL(req.url);
    if (req.method === "GET" && url.pathname === "/health") return Response.json({ ok: true });
    if (req.method === "POST" && url.pathname === "/render") {
      let body: any;
      try { body = await req.json(); } catch { return new Response("bad json", { status: 400 }); }
      const text = String(body?.text ?? "").trim();
      const voice = (body?.voice || "af_heart") as any;
      if (!text) return new Response("", { status: 204 });
      const stream = new ReadableStream({
        start(controller) {
          serialize(async () => {
            const dir = mkdtempSync(join(tmpdir(), "voz-"));
            let i = 0;
            for (const chunk of chunkText(text)) {
              if (req.signal.aborted) break; // client (curl) gone — stop rendering audio nobody hears
              let audio;
              try { audio = await tts.generate(chunk, { voice }); }
              catch { audio = await tts.generate(chunk, { voice: "af_heart" as any }); } // unknown voice → default
              if (req.signal.aborted) break;
              const path = join(dir, `chunk-${i++}.wav`);
              writeFileSync(path, toWav(audio.audio as Float32Array, audio.sampling_rate ?? 24000));
              try { controller.enqueue(enc.encode(path + "\t" + chunk + "\n")); }
              catch { break; } // response stream closed
            }
          }).finally(() => { try { controller.close(); } catch {} });
        },
      });
      return new Response(stream, { headers: { "Content-Type": "text/plain; charset=utf-8" } });
    }
    return new Response("not found", { status: 404 });
  },
});
