import Foundation

/// Spoken spelling. Say a word, then a cue and the letters — "Dhaval, that's D H A V A L" — and voz
/// takes the letters as the truth: it replaces the heard word with the spelled one, drops the spelling
/// phrase, and learns it *immediately* (you said it on purpose, so it skips the frequency gate). Future
/// dictations of that word are then auto-corrected everywhere.
///
///   "what's going on Dhaval that's D H A V A L with your work today"
///   → "what's going on Dhaval with your work today"   + learns  deval/dhaval → Dhaval
///
/// SAFETY: a spelling is recognized ONLY when an explicit cue ("that's", "spelled", "spell"…) sits
/// right before the letters. Without a cue, a run of single letters is left untouched — so ordinary
/// speech ("we sell a b c batteries", "J R R Tolkien", grades, stutters) can never be swallowed or,
/// worse, silently learned into your dictionary.
enum SpellOut {
    private enum Cue { case trigger, caps, lower }
    private static func cue(_ s: String) -> Cue? {
        switch s.lowercased() {
        case "that's", "thats", "spelled", "spelt", "spell", "spelling": return .trigger
        case "capital", "caps", "uppercase": return .caps
        case "lowercase": return .lower
        // NO connector words ("it", "is", "as"…): the cue must sit IMMEDIATELY before the letters, so
        // incidental single letters in normal speech can't be bridged into a spelling.
        default: return nil
        }
    }

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

            if letters.count >= 2, let plan = cueLookback() {
                out.removeLast(plan.strip) // drop the cue/connector tokens before the letters
                var heard: String?
                if let last = out.last, isWord(core(last)) { heard = core(last); out.removeLast() }
                let cased = applyCase(letters, upper: plan.upper, lower: plan.lower, like: heard)
                out.append(cased)
                // Learn ONLY a genuine misrecognition (the heard letters differ from what you spelled) —
                // never a casing-only rule, which would wrongly recase an ordinary word you spelled out.
                if let h = heard, h.lowercased() != letters.lowercased() { learned.append((h, cased)) }
                i = j
                continue
            }
            out.append(toks[i]); i += 1
        }

        /// Look back over `out` for cue/connector tokens immediately before the letter run. Returns how
        /// many to strip + the forced case — but ONLY if a real trigger cue ("that's"/"spelled"/…) is
        /// present. nil ⇒ not a spelling, leave the letters alone.
        func cueLookback() -> (strip: Int, upper: Bool, lower: Bool)? {
            var n = 0, trigger = false, upper = false, lower = false
            var p = out.count - 1
            while p >= 0, let k = cue(core(out[p])) {
                switch k {
                case .trigger: trigger = true
                case .caps: upper = true
                case .lower: lower = true
                }
                n += 1; p -= 1
            }
            return trigger ? (n, upper, lower) : nil
        }
        return (out.joined(separator: " "), dedupe(learned))
    }

    // MARK: helpers

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

    /// Case the spelled letters: forced upper/lower if you said "capital"/"lowercase"; else ALL-CAPS if
    /// the heard word already came through all-caps (an acronym), otherwise Title case (names).
    private static func applyCase(_ letters: String, upper: Bool, lower: Bool, like heard: String?) -> String {
        let low = letters.lowercased()
        if upper { return low.uppercased() }
        if lower { return low }
        if let h = heard, h.count > 1, h == h.uppercased() { return low.uppercased() }
        return low.prefix(1).uppercased() + low.dropFirst()
    }

    private static func dedupe(_ list: [(String, String)]) -> [(String, String)] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.0.lowercased()).inserted }
    }
}
