import AppKit

/// The local store behind voz Insights, all under ~/.voz:
///   history.json   — append-only JSON-Lines log of dictations (text + metrics)
///   audio/<id>.wav — the saved recording for each dictation (when audio-saving is on)
///   dictionary.json — the user dictionary (owned by Lexicon)
/// Loaded into memory; mirrors the dependency-free on-disk pattern Lexicon already uses. Everything
/// is local — never uploaded.
public final class InsightStore: ObservableObject {
    public static let shared = InsightStore()

    @Published private(set) var events: [DictationEvent] = []

    /// When off (stats-only), the transcript text isn't written to disk — every metric still is.
    var historyEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "insightsHistory") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "insightsHistory") }
    }
    /// Keep the recording so you can replay/relisten. Off → audio is deleted as before (nothing saved).
    var saveAudio: Bool {
        get { UserDefaults.standard.object(forKey: "insightsSaveAudio") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "insightsSaveAudio") }
    }

    let dir: URL          // ~/.voz
    private let fileURL: URL    // ~/.voz/history.json
    private let audioDir: URL   // ~/.voz/audio

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f // local timezone by default — the streak key
    }()

    private init() {
        dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".voz")
        fileURL = dir.appendingPathComponent("history.json")
        audioDir = dir.appendingPathComponent("audio")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        load()
    }

    // MARK: record

    /// Persist one dictation. `audioSource` is the temp WAV (still on disk); we copy it into the store
    /// when audio-saving is on. The caller deletes the temp WAV afterward.
    func record(_ cleaned: String, ctx: DictationContext, audioSource: URL?) {
        let text = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let id = UUID().uuidString
        if saveAudio, let src = audioSource {
            let dest = audioDir.appendingPathComponent("\(id).wav")
            try? FileManager.default.copyItem(at: src, to: dest)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
        }
        let e = DictationEvent(
            id: id,
            ts: Date().timeIntervalSince1970,
            day: Self.dayFormatter.string(from: Date()),
            text: historyEnabled ? text : "",
            words: Self.wordCount(text),
            durationMs: ctx.durationMs,
            appBundleId: ctx.appBundleId,
            appName: ctx.appName,
            engine: ctx.engine,
            kind: "dictate")
        events.append(e)
        appendLine(e)
    }

    static func wordCount(_ s: String) -> Int {
        s.split { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }.count
    }

    /// Log a read-aloud selection (kind "read"). No recording duration (it's TTS), so it never affects
    /// WPM. Public so the read-aloud side (a separate module) can route reads in via the app coordinator.
    public func recordRead(text: String, appBundleId: String?, appName: String?, voice: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let e = DictationEvent(
            id: UUID().uuidString,
            ts: Date().timeIntervalSince1970,
            day: Self.dayFormatter.string(from: Date()),
            text: historyEnabled ? t : "",
            words: Self.wordCount(t),
            durationMs: 0,
            appBundleId: appBundleId,
            appName: appName,
            engine: voice,
            kind: "read")
        events.append(e)
        appendLine(e)
    }

    // MARK: edit / delete (used from the History detail — "go train it")

    /// The saved recording for an event, if audio-saving kept it.
    func audioURL(for e: DictationEvent) -> URL? {
        let u = audioDir.appendingPathComponent("\(e.id).wav")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Correct a stored transcript (recomputes word count) and persist.
    func updateText(_ id: String, to newText: String) {
        guard let i = events.firstIndex(where: { $0.id == id }) else { return }
        let o = events[i]
        events[i] = DictationEvent(id: o.id, ts: o.ts, day: o.day, text: newText,
                                   words: Self.wordCount(newText), durationMs: o.durationMs,
                                   appBundleId: o.appBundleId, appName: o.appName, engine: o.engine, kind: o.kind)
        rewrite()
    }

    func delete(_ e: DictationEvent) {
        if let u = audioURL(for: e) { try? FileManager.default.removeItem(at: u) }
        events.removeAll { $0.id == e.id }
        rewrite()
    }

    // MARK: derived stats

    var dictations: [DictationEvent] { events.filter { $0.kind == "dictate" } }
    var reads: [DictationEvent] { events.filter { $0.kind == "read" } }
    var totalWords: Int { dictations.reduce(0) { $0 + $1.words } }   // words you dictated
    var wordsRead: Int { reads.reduce(0) { $0 + $1.words } }         // words read aloud

    var dayStreak: Int {
        guard !events.isEmpty else { return 0 }
        let days = Set(events.map { $0.day })
        let cal = Calendar.current
        var cursor = Date()
        if !days.contains(Self.dayFormatter.string(from: cursor)) {
            cursor = cal.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        var streak = 0
        while days.contains(Self.dayFormatter.string(from: cursor)) {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return streak
    }

    var avgWPM: Int {
        let timed = events.filter { $0.kind == "dictate" && $0.durationMs > 0 }
        let minutes = Double(timed.reduce(0) { $0 + $1.durationMs }) / 60_000.0
        guard minutes > 0 else { return 0 }
        return Int((Double(timed.reduce(0) { $0 + $1.words }) / minutes).rounded())
    }

    var totalWordsCompact: String { Self.compact(totalWords) }
    var wordsReadCompact: String { Self.compact(wordsRead) }
    static func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    /// Per-app usage ("where I use it"), most-used first.
    struct AppUsage: Identifiable { let id: String; let name: String; let words: Int; let count: Int }
    var perApp: [AppUsage] {
        var map: [String: (name: String, words: Int, count: Int)] = [:]
        for e in events where e.kind == "dictate" {
            let key = e.appBundleId ?? e.appName ?? "Unknown"
            var cur = map[key] ?? (e.appName ?? key, 0, 0)
            cur.words += e.words; cur.count += 1
            if let n = e.appName { cur.name = n }
            map[key] = cur
        }
        return map.map { AppUsage(id: $0.key, name: $0.value.name, words: $0.value.words, count: $0.value.count) }
            .sorted { $0.words > $1.words }
    }

    /// Distinct apps seen, for the History filter.
    var appFilters: [(key: String, name: String)] {
        perApp.map { ($0.id, $0.name) }
    }

    // MARK: persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let s = String(data: data, encoding: .utf8) else { return }
        let dec = JSONDecoder()
        events = s.split(separator: "\n").compactMap { try? dec.decode(DictationEvent.self, from: Data($0.utf8)) }
    }

    private func appendLine(_ e: DictationEvent) {
        guard let json = try? JSONEncoder().encode(e),
              var line = String(data: json, encoding: .utf8) else { return }
        line += "\n"
        let bytes = Data(line.utf8)
        if let fh = try? FileHandle(forWritingTo: fileURL) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: bytes)
        } else {
            try? bytes.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    /// Rewrite the whole log (after an edit/delete). Fine at single-user volume.
    private func rewrite() {
        let enc = JSONEncoder()
        let lines = events.compactMap { e -> String? in
            guard let d = try? enc.encode(e) else { return nil }
            return String(data: d, encoding: .utf8)
        }
        let blob = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try? Data(blob.utf8).write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
