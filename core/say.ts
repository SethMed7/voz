/**
 * voz's premium read-aloud voice: reads text on stdin, renders it sentence by
 * sentence with Kokoro (fully on-device), and prints one WAV path per line as
 * each chunk is ready — the app starts playing after the first line.
 * Installed to ~/.voz/kokoro by scripts/setup-kokoro.sh; run with bun.
 */
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const { env: hfEnv } = await import("@huggingface/transformers");
hfEnv.cacheDir = `${process.env.HOME}/.cache/huggingface-transformers`;
const { KokoroTTS } = await import("kokoro-js");

const text = (await new Response(Bun.stdin.stream()).text()).trim();
if (!text) process.exit(0);

function chunkText(input: string, max = 360): string[] {
  const sentences = input.replace(/\s+/g, " ").match(/[^.!?]+[.!?]+(\s|$)|[^.!?]+$/g) ?? [input];
  const chunks: string[] = [];
  let cur = "";
  for (const s of sentences) {
    if (cur && cur.length + s.length > max) {
      chunks.push(cur.trim());
      cur = "";
    }
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

const voice = (process.env.VOZ_VOICE ?? process.env.LEELO_VOICE ?? "af_heart") as Parameters<typeof tts.generate>[1] extends { voice?: infer V } ? V : never;
const dir = mkdtempSync(join(tmpdir(), "voz-"));
let i = 0;
for (const chunk of chunkText(text)) {
  const audio = await tts.generate(chunk, { voice });
  const path = join(dir, `chunk-${i++}.wav`);
  writeFileSync(path, toWav(audio.audio as Float32Array, audio.sampling_rate ?? 24000));
  // Emit "<path>\t<chunk text>" so the app can karaoke-highlight words as the
  // chunk plays. The chunk is whitespace-normalized, matching what we render.
  console.log(path + "\t" + chunk);
}
