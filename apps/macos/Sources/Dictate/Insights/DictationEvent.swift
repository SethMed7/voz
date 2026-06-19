import Foundation

/// One recorded dictation, persisted as a single JSON line in ~/.voz/history.json. Audio is never
/// saved; this is the cleaned text (empty in stats-only mode) plus the metrics that power the
/// dashboard. `day` is precomputed in the user's LOCAL timezone so streak math is a plain calendar
/// walk that can't drift at midnight/DST.
struct DictationEvent: Codable, Identifiable, Hashable {
    let id: String
    let ts: Double            // Unix epoch seconds, UTC — the source of truth for time
    let day: String           // "yyyy-MM-dd" in the user's local timezone — the streak / per-day key
    let text: String          // the full cleaned transcript ("" when History is off)
    let words: Int
    let durationMs: Int
    let appBundleId: String?
    let appName: String?
    let engine: String
    let kind: String          // "dictate" now; "read" reserved so read-aloud can share the log later

    var date: Date { Date(timeIntervalSince1970: ts) }
    var wpm: Int { durationMs > 0 ? Int((Double(words) / (Double(durationMs) / 60_000.0)).rounded()) : 0 }
}

/// The bits captured at dictation time that `deliver` doesn't otherwise have — threaded from
/// `transcribeAndDeliver` (which holds the clip) and from the frontmost app at recording start.
struct DictationContext {
    let durationMs: Int
    let engine: String
    let appBundleId: String?
    let appName: String?
}
