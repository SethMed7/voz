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

    private(set) var corrections: [String: String] = [:] // lowercased-from -> verbatim-to
    private let comment = "Map a misspelling (lowercase) to the spelling you want — e.g. \"myayla\": \"Myela\". voz applies these to every dictation, and adds to them when you correct a word."

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
        corrections = [:]
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let c = obj["corrections"] as? [String: String] else { return }
        for (k, v) in c where !k.isEmpty && !v.isEmpty { corrections[k.lowercased()] = v }
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

    /// Add/record a correction (from → to) and persist. No-op for a casing-only or empty change.
    func learn(from: String, to: String) {
        let key = from.lowercased()
        guard !key.isEmpty, !to.isEmpty, key != to.lowercased() else { return }
        corrections[key] = to
        save()
    }

    /// Remove a correction by its "from" key.
    func forget(_ from: String) {
        guard corrections.removeValue(forKey: from.lowercased()) != nil else { return }
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
        let obj: [String: Any] = ["_comment": comment, "corrections": corrections]
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: fileURL)
        }
    }
}
