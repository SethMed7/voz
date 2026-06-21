<div align="center">

<img src="apps/macos/media/logo.png" alt="voz — the voice layer for your Mac" width="720">

[![License: MIT](https://img.shields.io/badge/license-MIT-2E74FF)](LICENSE)
[![Platform](https://img.shields.io/badge/macOS-13%2B-161520)](#download)
[![Privacy](https://img.shields.io/badge/voice-on--device-2E74FF)](#privacy)

</div>

**voz** (Spanish for *voice*) is the voice layer for your Mac — a tiny menu-bar app, two halves of
one idea: **speak to type, select to hear.** It runs **100% on your Mac**: no cloud, no accounts, no
API keys, and **everything stays on your Mac** (your history + recordings are local-only, and you control them).

- 🎙 **Dictate** — hold **Fn** (or **double-tap Fn** for hands-free), speak, release. voz
  transcribes on-device, cleans it up — drops fillers ("um", "uh") and false starts, adds punctuation, formats
  numbers and dates — and types it where your cursor is, in any app.
- 🔊 **Read aloud** — select text anywhere and press **⌃V**. voz reads it in a warm neural voice,
  following along word by word.

## Download

### [⬇︎ Download voz for macOS](https://github.com/SethMed7/voz/releases/latest)

A **notarized `.dmg`** — open it, drag **voz** into Applications, launch. **macOS 13+.** No account,
no API key. It works **immediately** on Apple's built-in on-device engines; you only grant Microphone /
Accessibility the first time you use each mode.

Want the *premium* on-device engines (sharper dictation, warmer voices, LLM polish)? Open
**menu → "Set up better engines…"** — a transparent setup that checks your Mac and **asks before
installing anything**. Nothing is required; nothing happens without your yes.

## See it work

<div align="center">
<img src="apps/macos/media/showcase.png" alt="how voz works: speak → clean → type, on-device" width="860">
</div>

You talk the way you actually talk — fillers, self-corrections, even *"that's D H A V A L"* to spell
a name — and voz hands you clean, formatted text where your cursor is. It **learns the words you
correct** (and the ones you spell out), so names and jargon stick. Transcription runs from a warm
on-device engine, so it lands in well under a second — and nothing ever leaves your Mac.

## Highlights

- **100% on-device** — no cloud, no API keys, no accounts; your dictations and recordings are kept **local-only** in `~/.voz` (turn either off, or clear/export, in Insights ▸ Data & Privacy), never uploaded.
- **Genuinely clean output** — an optional on-device LLM removes fillers and false starts, adds punctuation, and formats numbers, currency, and dates (Wispr-class — still no cloud).
- **Near-instant** — a warm NVIDIA Parakeet engine transcribes in ~0.08 s instead of reloading the model every clip.
- **Learns your words** — correct a name a couple of times, or just spell it out loud (*"Dhaval, that's D H A V A L"*), and it sticks in your dictionary, everywhere — even in terminals.
- **Hands-free or hold** — double-tap **Fn** to toggle, or hold **Fn**; **Esc** cancels mid-dictation.
- **Reads back, too** — select any text + **⌃V** for warm, on-device neural read-aloud that follows along word by word.

## The two modes

### Dictate (voice → text)
Hold **Fn** and talk; a small electric-blue waveform reacts bottom-center while the mic is hot —
pause to think as long as you like, it records the whole hold and transcribes once on
release (a pause is never a stop). Prefer no hands? **Double-tap Fn** to start dictating and
double-tap again to stop. (If Fn opens emoji or Apple Dictation, set **System Settings ▸ Keyboard ▸
“Press 🌐 key to” → Do Nothing** so it's free for voz.) The cleaned text lands in the focused app. It learns
your spellings as you go (`myela` → `Myela`) via a local dictionary you control — and the
same dictionary teaches **read aloud** how to pronounce those words. If a paste ever lands in the
wrong place, the last several dictations are kept (in memory) under **menu → Copy Last Dictation**
(or **Recent Dictations**), so a mis-targeted paste never means re-saying it.

### Read aloud (text → voice)
Press **⌃V** to start watching, then highlight anything — drag-select, double/triple-click, or
**Shift-click to extend** — and each selection is queued in order and read aloud while a **dark
read-along panel** follows along word by word, the current word lit in electric blue. **⌃V always
(re)arms a fresh watch** (never a dead second press); **Esc stops** and closes. The panel wears voz's
identity — a black surface with a single electric-blue accent, the same card as the dictation pill —
and its **waveform only ripples while audio is actually playing** (motion, not a second color, is
what tells you it's live). Collapse to a compact player — waveform · play/pause · expand — with **⤡**;
it never steals focus. Or right-click → **Services → Read Aloud with voz** for a one-shot read.

### Look & feel
One identity across both modes: a **black surface with a single electric-blue accent** (`#2E74FF`),
SF Pro type, and **motion as the only "live" signal** — the waveform reacts only while the mic is hot
or audio is playing, never a second hue. The read-along panel and the dictation pill share the same
dark card, the menu-bar icon is the **V** sound-wave mark, and the loading/preparing states stay in
the same palette — so the two halves feel like one app. Full tokens in [`brand/tokens.md`](brand/tokens.md).

## Insights — your voice, tracked locally

Open **menu → Insights…** for a dark dashboard (same identity) that turns your dictation and
read-aloud into stats — **100% on your Mac**, nothing uploaded.

<div align="center">
<img src="apps/macos/media/insights.png" alt="voz Insights — Home stats, History with replay, Dictionary, and trend charts" width="860">
</div>

- **Home** — words dictated, your WPM, a day streak, words read aloud, and a recent feed.
- **Insights** — words-per-day, a speaking-pace (WPM) trend, and a per-app breakdown ("where you dictate").
- **History** — a searchable, per-app feed of every dictation; open one to **replay the recording**,
  fix the text, or **teach the dictionary** a word so future dictations get it right — train it as you go.
- **Dictionary** — your spelling corrections and read-aloud pronunciations, the learn-threshold, and where the file lives.
- **Data & Privacy** — toggles for keeping history, saving recordings, and skipping password fields,
  plus **Export** and **Clear**. Everything is local and owner-only; a spoken password is never stored.

## Permissions — you grant only what you turn on

Each mode has an on/off switch in the menu. voz asks for a permission the first time you use
the capability that needs it, and never before — and a mode you switch off never registers
its hotkey or asks for anything at all. When on, each mode lights up exactly these:

| You use… | Microphone | Speech Recognition | Accessibility |
| --- | :--: | :--: | :--: |
| **Read aloud** (⌃V) | – | – | ✓ (to read your selection) |
| **Dictate** (hold Fn) | ✓ | only if the Apple fallback engine is used | ✓ (to type the result) |
| **Learn-from-edits** dictionary | – | – | ✓ (to spot your in-place fixes) |

If you only ever read aloud, voz never touches your microphone.

## Development

**To use voz, [download the `.dmg`](#download) — that's the only install.** This section is just for
contributors hacking on the app:

```sh
# build + run locally from a checkout
cd apps/macos && sh scripts/bundle.sh && open build/voz.app
```

Optional premium engines install from the app's **menu → "Set up better engines…"** (capability-checked,
asks first). **Cut a release:** `sh scripts/release.sh` builds a Developer-ID-signed, **notarized**
`.dmg` in `dist/` (needs a Developer ID cert + a `voz-notary` notarytool profile in your Keychain;
no secrets ever live in the repo), then `gh release create v<ver> dist/voz-<ver>.dmg`.

## Engines — on-device and pluggable

voz uses the best engine present and falls through if one isn't installed. All run
**100% on your Mac**; the `core/` helpers and external binaries are cross-platform (no
Apple APIs), so only the app *shell* is macOS-specific.

- **Read aloud:** [Kokoro-82M](https://github.com/hexgrad/kokoro) neural voices (via
  `core/say.ts`), or the built-in macOS voice with zero setup. Optionally run Kokoro as a **warm
  local server** (`setup-kokoro-server.sh`, `core/say-server.ts`) that keeps the 92 MB model loaded
  so each read starts with consistent low latency instead of re-loading the model per selection —
  same model, same voices, 100% on-device (binds `127.0.0.1` only). It also streams a **short first
  chunk first**, so time-to-first-audio stays low (~0.5–1 s) and never balloons on a long opening
  sentence. If the server isn't installed or is unhealthy, voz falls back to the per-spawn renderer,
  then the system voice — the read never drops.
- **Dictate:** NVIDIA **Parakeet** (`sherpa-onnx`) → **whisper.cpp** → Apple's on-device
  recognizer, in that order of preference. Optionally run Parakeet as a **warm local server**
  (`setup-asr.sh`) that keeps the model loaded so each clip transcribes in ~0.08 s instead of
  ~1.5 s — same model, same quality, 100% on-device (binds `127.0.0.1` only). Cleanup defaults to a fast deterministic pass
  (`core/clean.ts`, no LLM), with an optional **on-device LLM polish** that adds real punctuation
  and removes contextual fillers ("like", "right", "you know"). **No Ollama, no separate app:** voz
  provisions its **own** engine — a **pinned** small open-weight model (Qwen2.5-1.5B-Instruct,
  Apache-2.0) run via **[MLX](https://github.com/ml-explore/mlx)** (Apple's Metal framework) and kept
  warm in a tiny loopback server (`core/llm-server.py`), the same warm-server pattern as Parakeet.
  The weights download only with your consent at setup, and the server is spawned **offline**
  (`HF_HUB_OFFLINE=1`) so transcript text can never leave the machine. Intel Macs (no MLX) fall back
  to a self-contained [llama.cpp](https://github.com/ggml-org/llama.cpp) + the same model. It is
  **guarded**: anything that changes your words rather than just punctuating/trimming them is
  discarded in favor of the deterministic result, and it falls back the same way if the model is
  missing or stalls.

These premium layers are all optional and fully on-device. Install them from the app's **menu →
"Set up better engines…"**, which checks your Mac and asks before each step — Kokoro neural voices
and the warm read-aloud server, Parakeet dictation and its warm server, and the MLX LLM polish (a
venv with `mlx-lm` plus the consented model download). The on-device homes install under `~/.voz`, and an existing
`~/.leelo` / `~/.dictado` install is migrated in place (no model re-download). Toggle the polish
under **menu → Dictate → "Polish with AI"**; pin a different model with `VOZ_LLM_MODEL=<mlx repo>`.

## What installs, and where

Everything the optional setup installs is **downloaded only with your explicit "y", and lives in
your home folder** — never inside the app, nothing system-wide, no admin/sudo: `~/.bun` (bun
runtime), `~/.voz/` (helper scripts, your dictionary + history, the warm servers, `kokoro/`,
`asr-venv/`, `llm-venv/`), `~/.cache/sherpa` (Parakeet engine + model, ~600 MB), and
`~/.cache/huggingface` (the MLX cleanup model, ~0.9 GB). Every engine runs locally and binds
`127.0.0.1` only. The app's **Set up better engines…** prints this same summary, and asks before
each step, so nothing installs without your yes.

## Privacy

No cloud, no API keys, no accounts, no telemetry — **everything stays on your Mac.** voz keeps a
**local** history of your dictations (and, when **Save recordings** is on, the audio) under `~/.voz`
(owner-only), so the Insights dashboard can show your stats, let you replay a clip, and learn your
words. You're in control in **Insights ▸ Data & Privacy**: turn **Keep history** off for stats-only
(no transcript text stored), turn **Save recordings** off to delete audio after transcription as it
always did, keep **Skip password fields** on so a spoken password is never written, and **Clear** or
**Export** anytime. Nothing is ever uploaded; the only network access is a one-time, explicit model
download when you opt into a premium engine, and the portable `core/` contains no networking code.

## Repository layout

```
voz/
├─ core/            portable, 100% on-device, cross-platform (no Apple APIs)
│   ├─ say.ts         Kokoro neural TTS (streaming)
│   ├─ clean.ts       deterministic transcript cleanup
│   ├─ asr-server.py  warm Parakeet ASR server (loopback)
│   ├─ llm-server.py  warm MLX LLM cleanup server (loopback)
│   └─ clean.test.ts  acceptance suite
├─ apps/
│   └─ macos/        the macOS menu-bar shell (SwiftPM)
│       └─ Sources/
│           ├─ Speak/    read-aloud capability (its own module)
│           ├─ Dictate/  dictation + the local Insights dashboard (its own module)
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

- **Insights AI** — optional on-device weekly summaries & suggested dictionary words (the local stats dashboard ships now).
- **Dictate → read-back** proofreading loop (speak it, hear it back to catch errors).
- Non-macOS shells over the same `core/`.

## License

MIT — see [LICENSE](LICENSE).

<div align="center">
<sub>🎙🔊 <b>voz</b> · voice in, voice out · 100% on-device · a blend of <b>leelo</b> + <b>dictado</b></sub>
</div>
