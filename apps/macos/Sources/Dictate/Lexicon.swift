import Foundation

/// Your personal dictionary: spelling corrections applied AFTER transcription + cleanup, just
/// before paste. Three ways in: hand-edit the JSON, the dashboard, or let the learn-listener add a
/// word when you fix it in place. Keys match case-insensitively on word boundaries; the value is
/// inserted verbatim, so "myela" → "Myela" fixes both the spelling and the casing.
///
/// Fully local. The file defaults to ~/.voz/dictionary.json but you can point it anywhere
/// (dashboard "Choose…", or the VOZ_DICTIONARY env var) — e.g. into a synced folder you control.
/// An existing ~/.dictado/dictionary.json (or DICTADO_DICTIONARY) is still honored as a fallback.
final class Lexicon {
    static let shared = Lexicon()

    private(set) var corrections: [String: String] = [:]    // lowercased-from -> verbatim-to (dictation)
    private(set) var pronunciations: [String: String] = [:] // lowercased-word -> "say it like" respelling (read-aloud)

    /// Candidate fixes grouped by the TARGET word you want (keyed by its lowercase) — e.g. every way
    /// the engine mis-hears "Dhaval" ("devil", "duval", …) collects under "dhaval". Once you've
    /// corrected toward that target `learnThreshold` times (across any spelling), all those
    /// mis-hearings are promoted to real rules at once. Counting by target — not by each mis-hearing —
    /// is what makes a name stick even when the recognizer hears it differently each time.
    private(set) var pending: [String: PendingTarget] = [:]

    struct PendingTarget { var to: String; var froms: Set<String>; var count: Int }

    /// How many times you must make the same in-place fix before voz adds it as a rule. Default 2;
    /// set it in the Dictionary window. So "Deval"→"Dhaval" becomes a rule on the 2nd time you fix it.
    var learnThreshold: Int {
        get { max(1, UserDefaults.standard.object(forKey: "learnThreshold") as? Int ?? 2) }
        set { UserDefaults.standard.set(max(1, newValue), forKey: "learnThreshold") }
    }

    enum LearnOutcome {
        case promoted(to: String)                            // crossed the threshold → now a rule
        case pending(to: String, count: Int, threshold: Int) // tallied, not yet a rule
        case ignored                                         // nothing to learn
    }

    private let comment = "corrections: map a misspelling (lowercase) to the spelling you want — e.g. \"myayla\": \"Myela\"; voz applies these to every dictation. pronunciations: map a word (lowercase) to how read-aloud should say it — e.g. \"myela\": \"my-ell-uh\"."

    init() { load() }

    /// Resolved dictionary file: VOZ_DICTIONARY/DICTADO_DICTIONARY env → saved location →
    /// ~/.voz (or an existing ~/.dictado). Always a file path.
    var fileURL: URL {
        for key in ["VOZ_DICTIONARY", "DICTADO_DICTIONARY"] {
            if let env = ProcessInfo.processInfo.environment[key], !env.isEmpty {
                return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
            }
        }
        if let saved = UserDefaults.standard.string(forKey: "dictionaryPath"), !saved.isEmpty {
            return URL(fileURLWithPath: saved)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let voz = home.appendingPathComponent(".voz/dictionary.json")
        let legacy = home.appendingPathComponent(".dictado/dictionary.json")
        if FileManager.default.fileExists(atPath: voz.path) { return voz }
        if FileManager.default.fileExists(atPath: legacy.path) { return legacy } // keep prior dictionary loading
        return voz // fresh installs write here
    }

    func load() {
        corrections = [:]; pronunciations = [:]; pending = [:]
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let c = obj["corrections"] as? [String: String] {
            for (k, v) in c where !k.isEmpty && !v.isEmpty { corrections[k.lowercased()] = v }
        }
        if let p = obj["pronunciations"] as? [String: String] {
            for (k, v) in p where !k.isEmpty && !v.isEmpty { pronunciations[k.lowercased()] = v }
        }
        if let pend = obj["pending"] as? [String: [String: Any]] {
            for (k, v) in pend {
                guard !k.isEmpty, let to = v["to"] as? String, !to.isEmpty,
                      let count = v["count"] as? Int, count > 0 else { continue }
                let froms = Set((v["froms"] as? [String] ?? []).map { $0.lowercased() }.filter { !$0.isEmpty })
                pending[k.lowercased()] = PendingTarget(to: to, froms: froms, count: count)
            }
        }
    }

    /// Apply known corrections to a transcript — whole words only, case-insensitive.
    func apply(_ text: String) -> String {
        guard !corrections.isEmpty else { return text }
        var result = text
        for (from, to) in corrections {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: from) + "\\b"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = re.stringByReplacingMatches(in: result, range: range,
                                                 withTemplate: NSRegularExpression.escapedTemplate(for: to))
        }
        return result
    }

    /// Add/record a correction (from → to) and persist immediately — the dashboard's manual "Add",
    /// which is an explicit rule, so it skips the frequency gate. No-op for a casing-only or empty
    /// change. Clears any pending tally toward the same target.
    func learn(from: String, to: String) {
        let key = from.lowercased()
        guard !key.isEmpty, !to.isEmpty, key != to.lowercased() else { return }
        corrections[key] = to
        pending.removeValue(forKey: to.lowercased())
        save()
    }

    /// Store a spelled-out correction (from → to) immediately — you said it on purpose, so it skips
    /// the frequency gate. Unlike `learn`, this allows a casing-only rule (e.g. "dhaval" → "Dhaval").
    func learnExplicit(from: String, to: String) {
        let key = from.lowercased().trimmingCharacters(in: .whitespaces)
        let value = to.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.isEmpty, from.trimmingCharacters(in: .whitespaces) != value else { return }
        corrections[key] = value
        pending.removeValue(forKey: value.lowercased())
        save()
    }

    /// Record an in-place fix you made (from → to), frequency-gated and grouped by target. Each
    /// correction toward the same target word counts up — across however many ways the recognizer
    /// mis-heard it — and once the count reaches `learnThreshold`, every mis-hearing seen is promoted
    /// to a real rule at once.
    func recordCorrection(from: String, to: String) -> LearnOutcome {
        let fromKey = from.lowercased()
        let target = to.trimmingCharacters(in: .whitespaces)
        let targetKey = target.lowercased()
        guard !fromKey.isEmpty, !target.isEmpty, fromKey != targetKey else { return .ignored }
        if corrections[fromKey]?.lowercased() == targetKey { return .ignored } // this mapping is already a rule

        let threshold = learnThreshold
        var p = pending[targetKey] ?? PendingTarget(to: target, froms: [], count: 0)
        p.to = target              // keep the latest casing you typed
        p.froms.insert(fromKey)
        p.count += 1

        if p.count >= threshold {
            for f in p.froms { corrections[f] = p.to }
            pending.removeValue(forKey: targetKey)
            save()
            return .promoted(to: p.to)
        }
        pending[targetKey] = p
        save()
        return .pending(to: p.to, count: p.count, threshold: threshold)
    }

    /// Remove a single correction rule by its "from" key (the dashboard's Corrections list).
    func forget(_ from: String) {
        guard corrections.removeValue(forKey: from.lowercased()) != nil else { return }
        save()
    }

    /// Undo a just-learned target: drop every correction rule that maps to it (the "Saved" pill's Remove).
    func forgetTarget(_ to: String) {
        let before = corrections.count
        corrections = corrections.filter { $0.value.lowercased() != to.lowercased() }
        if corrections.count != before { save() }
    }

    /// Drop a not-yet-promoted candidate by its target key (the dashboard's "Learning" list).
    func forgetPending(_ targetKey: String) {
        guard pending.removeValue(forKey: targetKey.lowercased()) != nil else { return }
        save()
    }

    /// Set how read-aloud should say `word` — a respelling like "my-ell-uh". An empty `say` clears it.
    /// Stored in the same file the read-aloud Pronouncer reads, so dictation and reading share it.
    func setPronunciation(word: String, say: String) {
        let key = word.lowercased().trimmingCharacters(in: .whitespaces)
        let value = say.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        if value.isEmpty { pronunciations.removeValue(forKey: key) } else { pronunciations[key] = value }
        save()
    }

    /// Remove a pronunciation by its word key.
    func forgetPronunciation(_ word: String) {
        guard pronunciations.removeValue(forKey: word.lowercased()) != nil else { return }
        save()
    }

    /// Point the dictionary at a new location (file or folder). Carries current entries over if the
    /// target is empty; adopts the target's entries if it already has some.
    func setLocation(_ picked: URL) {
        var target = picked
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: picked.path, isDirectory: &isDir)
        if (exists && isDir.boolValue) || picked.pathExtension.isEmpty {
            target = picked.appendingPathComponent("dictionary.json")
        }
        UserDefaults.standard.set(target.path, forKey: "dictionaryPath")
        if !FileManager.default.fileExists(atPath: target.path) { save() } // migrate current entries
        load()
    }

    /// Back to the built-in default location.
    func resetLocation() {
        UserDefaults.standard.removeObject(forKey: "dictionaryPath")
        load()
    }

    /// Create the file with a self-documenting template if it doesn't exist yet.
    @discardableResult
    func ensureFileExists() -> URL {
        if !FileManager.default.fileExists(atPath: fileURL.path) { save() }
        return fileURL
    }

    private func save() {
        var pendingObj: [String: [String: Any]] = [:]
        for (k, v) in pending { pendingObj[k] = ["to": v.to, "count": v.count, "froms": Array(v.froms).sorted()] }
        let obj: [String: Any] = ["_comment": comment, "corrections": corrections,
                                  "pronunciations": pronunciations, "pending": pendingObj]
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: fileURL)
        }
    }
}
