# voz Insights — build plan

A local dashboard inside voz that turns dictation into stats + a searchable history, in voz's
dark / electric-blue identity. **100% on-device.** Audio is still never saved; transcripts are now
stored **local-only** (when History is on), clearable and exportable.

## Architecture
- **One SwiftUI window** (`NSHostingView` in an `NSWindow`) — the rest of the app stays AppKit. The
  menu bar, status item, overlays, and pills are untouched.
- **Capture** is one funnel: every finished dictation passes through `DictateController.deliver`.
  A small context (duration → WPM, engine, and the **frontmost app captured at recording start** so
  per-app isn't just "voz") is threaded down and recorded as one `DictationEvent`.
- **Storage:** append-only **JSON-Lines** at `~/.voz/history.json` (mirrors the proven
  `dictionary.json` pattern), loaded into an `InsightStore` observable. No SQLite, no new deps — at a
  single user's volume this loads/searches in memory trivially. SQLite stays a documented later
  migration only if volume ever demands it.
- **Theme:** `VozTheme.swift` carries the dark + single electric-blue palette (from `brand/tokens.md`)
  into SwiftUI. One accent only; chart series differ by length/opacity, never a second hue.

## Data model — `DictationEvent` (one JSON line)
`id · ts (UTC) · day (local YYYY-MM-DD, precomputed so streaks survive midnight/DST) · text · words ·
durationMs · appBundleId · appName · engine · kind` ("dictate" now; "read" reserved). When History is
off, `text` is empty but every metric still lands (stats-only mode).

## Phases
1. **Capture + store + Home stat cards** — total words · day streak · WPM. *(this slice)*
2. **History feed + per-app usage** — searchable/filterable feed, app icons, export/clear.
3. **Dictionary redesign + Data & Privacy** — port the lexicon UI in; history toggle, secure-field
   exclusion, retention, clear/export. Rewrite the README privacy lines in the same release.
4. **Insights charts** — words/day, WPM trend, per-app bars (single-hue, Swift Charts).
5. **Local AI insights (optional)** — weekly summary, suggested dictionary words, nudges; reuses the
   on-device Ollama/llama.cpp path; cached; master switch (default-off).

## Privacy
Audio never saved (temp WAV deleted the moment text exists). Transcripts persist **local-only**
(`~/.voz`, `0600`), with a **stats-only toggle**, **secure-field / password-manager exclusion** (a
spoken password is never written), **Clear / Export**, and owner-only perms. The README's
"transcripts are never written to disk" claim must be rewritten when Phase 3 ships the controls.

## Decisions (locked)
JSONL store · History default-on · 5-section sidebar (Home / Insights / Dictionary / History +
Data&Privacy) · per-app = horizontal bars · AI master switch default-off · read-aloud tracking
deferred (schema reserves `kind`).
