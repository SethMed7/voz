import Foundation

/// Spoken spelling. When you spell a word out loud mid-dictation — "Dhaval, that's D H A V A L" —
/// voz takes the spelled letters as the truth: it replaces the heard word with the spelled one, drops
/// the spelling phrase from the text, and learns it *immediately* (you said it on purpose, so it skips
/// the frequency gate). Future dictations of that word are then auto-corrected everywhere.
///
///   "what's going on Dhaval that's D H A V A L with your work today"
///   → "what's going on Dhaval with your work today"   + learns  deval/dhaval → Dhaval
enum SpellOut {
    /// Words that sit between the spoken word and its spelling — stripped from the output.
    private static let cues: Set<String> = [
        "that's", "thats", "that", "is", "spelled", "spelt", "spell", "spelling",
        "as", "in", "capital", "caps", "lowercase", "uppercase", "like", "it",
    ]

    /// De-spelled text + the (from → to) rules to learn.
    static func process(_ text: String) -> (text: String, learned: [(from: String, to: String)]) {
        let toks = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        var out: [String] = []
        var learned: [(String, String)] = []
        var i = 0
        while i < toks.count {
            // Collect a run of single-letter tokens ("D", "h", "A.", …) starting here.
            var j = i
            var letters = ""
            while j < toks.count, let c = singleLetter(toks[j]) { letters.append(c); j += 1 }

            if letters.count >= 3 { // 3+ spelled letters in a row = a spelling, not normal speech
                while let last = out.last, cues.contains(core(last).lowercased()) { out.removeLast() }
                var heard: String?
                if let last = out.last, isWord(core(last)) { heard = core(last); out.removeLast() }

                let cased = applyCase(letters, like: heard)
                out.append(cased)
                let canon = letters.lowercased()
                if canon != cased { learned.append((canon, cased)) }                 // lock the spelling+casing
                if let h = heard, h.lowercased() != canon { learned.append((h, cased)) } // map the misrecognition
                i = j
                continue
            }
            out.append(toks[i]); i += 1
        }
        return (out.joined(separator: " "), dedupe(learned))
    }

    // MARK: helpers

    /// The single letter a token spells, ignoring surrounding punctuation ("A," → "a"); else nil.
    private static func singleLetter(_ token: String) -> Character? {
        let c = core(token)
        return (c.count == 1 && (c.first?.isLetter ?? false)) ? c.first : nil
    }

    /// Token stripped of leading/trailing non-alphanumerics (keeps inner apostrophes like "that's").
    private static func core(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    private static func isWord(_ s: String) -> Bool {
        s.count >= 2 && s.allSatisfy { $0.isLetter || $0 == "'" }
    }

    /// Case the spelled letters: ACRONYM if the heard word was all-caps, otherwise Title case (names).
    private static func applyCase(_ letters: String, like heard: String?) -> String {
        let lower = letters.lowercased()
        if let h = heard, h.count > 1, h == h.uppercased() { return lower.uppercased() }
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }

    private static func dedupe(_ list: [(String, String)]) -> [(String, String)] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.0.lowercased()).inserted }
    }
}
