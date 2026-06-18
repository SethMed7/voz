<div align="center">

<img src="apps/macos/media/logo.png" alt="voz — the voice layer for your Mac" width="720">

[![License: MIT](https://img.shields.io/badge/license-MIT-2E74FF)](LICENSE)
[![Platform](https://img.shields.io/badge/macOS-13%2B-161520)](#install)
[![Privacy](https://img.shields.io/badge/voice-on--device-2E74FF)](#privacy)

</div>

**voz** (Spanish for *voice*) is the voice layer for your Mac — a tiny menu-bar app, two halves of
one idea: **speak to type, select to hear.** It runs **100% on your Mac**: no cloud, no accounts, no
API keys, and **no recording is ever saved.**

- 🎙 **Dictate** — hold **⌃ + ⌥** (or **double-tap ⌃** for hands-free), speak, release. voz
  transcribes on-device, cleans it up — drops fillers ("um", "uh") and false starts, adds punctuation, formats
  numbers and dates — and types it where your cursor is, in any app.
- 🔊 **Read aloud** — select text anywhere and press **⌃V**. voz reads it in a warm neural voice,
  following along word by word.

## See it work

<div align="center">
<img src="apps/macos/media/showcase.png" alt="how voz works: speak → clean → type, on-device" width="860">
</div>

You talk the way you actually talk — fillers, self-corrections, even *"that's D H A V A L"* to spell
a name — and voz hands you clean, formatted text where your cursor is. It **learns the words you
correct** (and the ones you spell out), so names and jargon stick. Transcription runs from a warm
on-device engine, so it lands in well under a second — and nothing ever leaves your Mac.

## Highlights

- **100% on-device** — no cloud, no API keys, no accounts; audio is transcribed and deleted in one pass, never saved.
- **Genuinely clean output** — an optional on-device LLM removes fillers and false starts, adds punctuation, and formats numbers, currency, and dates (Wispr-class — still no cloud).
- **Near-instant** — a warm NVIDIA Parakeet engine transcribes in ~0.08 s instead of reloading the model every clip.
- **Learns your words** — correct a name a couple of times, or just spell it out loud (*"Dhaval, that's D H A V A L"*), and it sticks in your dictionary, everywhere — even in terminals.
- **Hands-free or hold** — double-tap **⌃** to toggle, or hold **⌃ + ⌥**; **Esc** cancels mid-dictation.
- **Reads back, too** — select any text + **⌃V** for warm, on-device neural read-aloud that follows along word by word.

## The two modes

### Dictate (voice → text)
Hold **⌃ + ⌥** and talk; a small electric-blue waveform reacts bottom-center while the mic is hot —
pause to think as long as you like, it records the whole hold and transcribes once on
release (a pause is never a stop). Prefer no hands? **Double-tap ⌃** to start dictating and
double-tap again to stop. The cleaned text lands in the focused app. It learns
your spellings as you go (`myela` → `Myela`) via a local dictionary you control — and the
same dictionary teaches **read aloud** how to pronounce those words.

### Read aloud (text → voice)
Press **⌃V** to start watching, then highlight anything — each selection is queued in
order and read along word by word in a minimized player that never steals focus. Or
right-click → **Services → Read Aloud with voz** for a one-shot read.

## Permissions — you grant only what you turn on

Each mode has an on/off switch in the menu. voz asks for a permission the first time you use
the capability that needs it, and never before — and a mode you switch off never registers
its hotkey or asks for anything at all. When on, each mode lights up exactly these:

| You use… | Microphone | Speech Recognition | Accessibility |
| --- | :--: | :--: | :--: |
| **Read aloud** (⌃V) | – | – | ✓ (to read your selection) |
| **Dictate** (hold ⌃+⌥) | ✓ | only if the Apple fallback engine is used | ✓ (to type the result) |
| **Learn-from-edits** dictionary | – | – | ✓ (to spot your in-place fixes) |

If you only ever read aloud, voz never touches your microphone.

## Install

```sh
# build + install to /Applications, then launch
cd apps/macos && sh scripts/install.sh
```

The first time you use each mode, macOS prompts for the permission above. With a stable
signing identity those grants carry across updates.

## Engines — on-device and pluggable

voz uses the best engine present and falls through if one isn't installed. All run
**100% on your Mac**; the `core/` helpers and external binaries are cross-platform (no
Apple APIs), so only the app *shell* is macOS-specific.

- **Read aloud:** [Kokoro-82M](https://github.com/hexgrad/kokoro) neural voices (via
  `core/say.ts`), or the built-in macOS voice with zero setup.
- **Dictate:** NVIDIA **Parakeet** (`sherpa-onnx`) → **whisper.cpp** → Apple's on-device
  recognizer, in that order of preference. Optionally run Parakeet as a **warm local server**
  (`setup-asr.sh`) that keeps the model loaded so each clip transcribes in ~0.08 s instead of
  ~1.5 s — same model, same quality, 100% on-device (binds `127.0.0.1` only). Cleanup defaults to a fast deterministic pass
  (`core/clean.ts`, no LLM), with an optional **on-device LLM polish** that adds real punctuation
  and removes contextual fillers ("like", "right", "you know"). The polish **reuses a local LLM
  runtime you already run** — it prefers an existing **[Ollama](https://ollama.com)** (the same
  one tools like Breve use, so nothing is installed twice; a *thinking* model such as gemma is
  auto-run with thinking off, so it answers in ~1s), and falls back to a self-contained
  [llama.cpp](https://github.com/ggml-org/llama.cpp) + small open-weight model
  (Qwen2.5-1.5B-Instruct, Apache-2.0) on machines with no Ollama. It is **guarded**: anything that
  changes your words rather than just punctuating/trimming them is discarded in favor of the
  deterministic result, and it falls back the same way if the model is missing or stalls.

These premium layers are all optional and fully on-device. Enable them with
`sh scripts/setup-kokoro.sh` (Kokoro voices), `sh scripts/setup-helper.sh` (Parakeet + the
canonical cleaner), `sh scripts/setup-asr.sh` (the warm Parakeet server — near-instant
transcription), and `sh scripts/setup-cleaner.sh` (the LLM polish — which just confirms your
existing Ollama, or sets one up). The on-device homes install under `~/.voz`, and an existing
`~/.leelo` / `~/.dictado` install is migrated in place (no model re-download). Toggle the polish
under **menu → Dictate → "Polish with AI"**; pin a model with `VOZ_OLLAMA_MODEL=<name>`.

## Privacy

No cloud, no API keys, no accounts, no telemetry. Audio is transcribed and deleted in one
pass — **no recording is ever saved**. The only network access is a one-time, explicit model
download when you opt into a premium engine. The portable `core/` contains no networking code.

## Repository layout

```
voz/
├─ core/            portable, 100% on-device, cross-platform (no Apple APIs)
│   ├─ say.ts         Kokoro neural TTS (streaming)
│   ├─ clean.ts       deterministic transcript cleanup
│   └─ clean.test.ts  acceptance suite
├─ apps/
│   └─ macos/        the macOS menu-bar shell (SwiftPM)
│       └─ Sources/
│           ├─ Speak/    read-aloud capability (its own module)
│           ├─ Dictate/  dictation capability (its own module)
│           └─ voz/      the coordinator: hosts both behind one status item
├─ brand/           the voz identity (tokens, usage)
└─ README.md
```

The two capabilities are **separate Swift modules** so their internals never collide; the
thin `voz` executable hosts both and owns the single shared menu-bar item. Tomorrow a
non-macOS shell (or another project of yours) can embed `core/` untouched.

## Development

```sh
cd apps/macos
swift build                              # debug build
sh scripts/bundle.sh                     # release -> build/voz.app
sh scripts/install.sh                    # build, sign, install to /Applications, launch

# headless smoke tests (no UI, no permissions):
.build/debug/voz --version
.build/debug/voz --speak "hello"         # read-aloud pipeline
.build/debug/voz --clean "um so the the report"   # deterministic cleanup
.build/debug/voz --polish "um so like the the report"  # full chain (on-device LLM if installed)
.build/debug/voz --engine                # which transcription engine would run
.build/debug/voz --apply "ship the miele engine"  # apply your dictionary (dictation)
.build/debug/voz --pronounce "read Myela aloud"   # apply your pronunciations (read-aloud)
.build/debug/voz --selftest              # learn-from-edits logic
```

## Roadmap

- **Dictate → read-back** proofreading loop (speak it, hear it back to catch errors).
- Non-macOS shells over the same `core/`.

## License

MIT — see [LICENSE](LICENSE).

<div align="center">
<sub>🎙🔊 <b>voz</b> · voice in, voice out · 100% on-device · a blend of <b>leelo</b> + <b>dictado</b></sub>
</div>
