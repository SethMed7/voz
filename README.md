<div align="center">

<img src="apps/macos/media/banner.png" alt="voz" width="640">

**the voice layer for your Mac — speak to type, select to hear. 100% on-device.**

[![License: MIT](https://img.shields.io/badge/license-MIT-6E56E8)](LICENSE)
[![Platform](https://img.shields.io/badge/macOS-13%2B-161520)](#install)
[![Privacy](https://img.shields.io/badge/voice-on--device-22C7A9)](#privacy)

</div>

**voz** (Spanish for *voice*) is a tiny menu-bar app with two halves of one idea:

- **Dictate** — hold **⌃ + Fn**, speak, release. What you said is transcribed on your Mac,
  cleaned (fillers and self-corrections dropped), and typed where your cursor is.
- **Read aloud** — select text anywhere and press **⌃⇧V**. voz reads it in a warm neural
  voice and follows along word by word.

One menu-bar item, one mental model: *voice in, voice out.* Nothing you say or read ever
leaves your computer. voz is the blend of two earlier tools —
[leelo](https://github.com/SethMed7/leelo) (read aloud) and
[dictado](https://github.com/SethMed7/dictado) (dictate) — folded into a single product.

## The two modes

### Dictate (voice → text)
Hold **⌃ + Fn** and talk; a small jade dot pulses bottom-center while the mic is hot —
pause to think as long as you like, it records the whole hold and transcribes once on
release (a pause is never a stop). The cleaned text lands in the focused app. It learns
your spellings as you go (`myela` → `Myela`) via a local dictionary you control.

### Read aloud (text → voice)
Press **⌃⇧V** to start watching, then highlight anything — each selection is queued in
order and read along word by word in a minimized player that never steals focus. Or
right-click → **Services → Read Aloud with voz** for a one-shot read.

## Permissions — you grant only what you turn on

voz asks for a permission the first time you use the capability that needs it, and never
before. Each mode lights up exactly these:

| You use… | Microphone | Speech Recognition | Accessibility |
| --- | :--: | :--: | :--: |
| **Read aloud** (⌃⇧V) | – | – | ✓ (to read your selection) |
| **Dictate** (hold ⌃+Fn) | ✓ | only if the Apple fallback engine is used | ✓ (to type the result) |
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
  recognizer, in that order of preference. Cleanup is deterministic (`core/clean.ts`), no LLM.

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
.build/debug/voz --clean "um so the the report"   # dictation cleanup
.build/debug/voz --engine                # which transcription engine would run
.build/debug/voz --apply "ship the miele engine"  # apply your dictionary
.build/debug/voz --selftest              # learn-from-edits logic
```

## Roadmap

- **Capability toggles** in the menu (turn a mode fully off → its permission is never asked).
- **One shared dictionary** so the spellings dictation learns also teach read-aloud how to
  pronounce them.
- **Dictate → read-back** proofreading loop (speak it, hear it back to catch errors).
- Non-macOS shells over the same `core/`.

## License

MIT — see [LICENSE](LICENSE).

<div align="center">
<sub>🎙🔊 <b>voz</b> · voice in, voice out · 100% on-device · a blend of
<a href="https://github.com/SethMed7/leelo">leelo</a> +
<a href="https://github.com/SethMed7/dictado">dictado</a></sub>
</div>
