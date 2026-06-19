import AppKit

/// The local store behind voz Insights: an append-only JSON-Lines log of dictations at
/// ~/.voz/history.json, loaded into memory, plus the derived stats the dashboard shows. Mirrors the
/// dependency-free on-disk pattern Lexicon already uses. Everything is local — never uploaded.
/// All access is on the main thread (deliver runs on main; the views observe on main), so no actor
/// annotation is needed — keeping it off `@MainActor` avoids isolation friction with the AppKit caller.
final class InsightStore: ObservableObject {
    static let shared = InsightStore()

    @Published private(set) var events: [DictationEvent] = []

    /// When off (stats-only), the transcript text isn't written to disk — every metric still is.
    var historyEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "insightsHistory") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "insightsHistory") }
    }

    private let fileURL: URL
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f // local timezone by default — the streak key
    }()

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".voz")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        fileURL = dir.appendingPathComponent("history.json")
        load()
    }

    // MARK: record

    func record(_ cleaned: String, ctx: DictationContext) {
        let text = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let e = DictationEvent(
            id: UUID().uuidString,
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

    // MARK: derived stats

    var totalWords: Int { events.reduce(0) { $0 + $1.words } }

    /// Consecutive local days with at least one dictation, counted back from today (or yesterday if
    /// nothing's been dictated yet today — the streak is still alive until the day ends).
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

    /// Words per spoken minute across all dictations that have a duration.
    var avgWPM: Int {
        let timed = events.filter { $0.durationMs > 0 }
        let minutes = Double(timed.reduce(0) { $0 + $1.durationMs }) / 60_000.0
        guard minutes > 0 else { return 0 }
        return Int((Double(timed.reduce(0) { $0 + $1.words }) / minutes).rounded())
    }

    /// "56.7K"-style compact word count for the stat card.
    var totalWordsCompact: String {
        let n = totalWords
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    // MARK: persistence (append-only JSON Lines)

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let s = String(data: data, encoding: .utf8) else { return }
        let dec = JSONDecoder()
        events = s.split(separator: "\n").compactMap { line in
            try? dec.decode(DictationEvent.self, from: Data(line.utf8))
        }
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
            // First write — create owner-only.
            try? bytes.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }
}
