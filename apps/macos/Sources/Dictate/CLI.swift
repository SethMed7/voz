import AppKit
import ApplicationServices

/// Headless entries for the dictation pipeline (CI / dev smoke tests). No UI, no hotkey.
/// `--clean`, `--polish`, `--transcribe`, `--engine`, `--apply`, `--selftest`, `--axcheck`, `--learn-test`.
public enum DictateCLI {
    /// Returns true if it handled the args (the caller should then exit).
    public static func handle(_ args: [String]) -> Bool {
        if args.contains("--axcheck") {
            // Does THIS app have Accessibility? (no prompt) — auto-paste AND learn-from-edits need it.
            print(AXIsProcessTrusted() ? "accessibility: GRANTED" : "accessibility: NOT granted")
            return true
        }
        if args.contains("--axprobe") {
            // Focus the app/field to test (e.g. Claude Code in Ghostty), then we report what voz can read.
            FileHandle.standardError.write(Data("Focus the field to test (e.g. Claude Code in Ghostty)… probing in 4s\n".utf8))
            Thread.sleep(forTimeInterval: 4)
            print(CorrectionListener.probe())
            return true
        }
        if let i = args.firstIndex(of: "--learn-test"), i + 2 < args.count {
            // Prove the frequency tally headlessly. Point VOZ_DICTIONARY at a temp file to avoid
            // touching your real dictionary: VOZ_DICTIONARY=/tmp/t.json voz --learn-test deval Dhaval
            let from = args[i + 1], to = args[i + 2]
            Lexicon.shared.load()
            let threshold = Lexicon.shared.learnThreshold
            print("threshold = \(threshold); simulating \(threshold) identical fixes of \(from) → \(to)")
            for n in 1...threshold {
                switch Lexicon.shared.recordCorrection(from: from, to: to) {
                case .promoted(let w):              print("  fix #\(n): PROMOTED → rule '\(from.lowercased())' → '\(w)'")
                case .pending(let w, let c, let t): print("  fix #\(n): pending '\(w)' (\(c) of \(t))")
                case .ignored:                      print("  fix #\(n): ignored")
                }
            }
            print("dictionary now maps '\(from.lowercased())' → \(Lexicon.shared.corrections[from.lowercased()] ?? "(none)")")
            return true
        }
        if let i = args.firstIndex(of: "--clean"), i + 1 < args.count {
            print(BasicCleaner.cleaned(args[i + 1])) // deterministic pass only
            return true
        }
        if let i = args.firstIndex(of: "--spell"), i + 1 < args.count {
            let r = SpellOut.process(args[i + 1])
            print("text:  \(r.text)")
            for rule in r.learned { print("learn: \(rule.from) -> \(rule.to)") }
            return true
        }
        if let i = args.firstIndex(of: "--polish"), i + 1 < args.count {
            // Full cleaner chain: the on-device LLM when installed, else deterministic.
            print(Cleaners.best().clean(args[i + 1]))
            return true
        }
        if let i = args.firstIndex(of: "--transcribe"), i + 1 < args.count {
            let wav = URL(fileURLWithPath: args[i + 1])
            var result = ""
            // Completion posts to the main queue; run the main loop so it can drain.
            Transcribers.run(wav, clipDuration: 10) { text in result = text; CFRunLoopStop(CFRunLoopGetMain()) }
            CFRunLoopRunInMode(.defaultMode, 60, false)
            print(result)
            return true
        }
        if args.contains("--engine") {
            print(Transcribers.activeEngineName())
            return true
        }
        if let i = args.firstIndex(of: "--apply"), i + 1 < args.count {
            Lexicon.shared.load() // honors DICTADO_DICTIONARY for a non-default location
            print(Lexicon.shared.apply(args[i + 1]))
            return true
        }
        if args.contains("--selftest") {
            runSelftest()
            return true
        }
        return false
    }

    /// Verify the learn-from-edits detection logic headlessly.
    private static func runSelftest() {
        var fails = 0
        func check(_ ok: Bool, _ name: String) { print((ok ? "ok   " : "FAIL ") + name); if !ok { fails += 1 } }

        check(CorrectionListener.levenshtein("miele", "myela") == 2, "levenshtein miele/myela == 2")
        check(CorrectionListener.levenshtein("cat", "cat") == 0, "levenshtein identical == 0")

        let d1 = CorrectionListener.detectCorrection(
            baseline: ["ship", "the", "miele", "engine", "today"],
            current: ["ship", "the", "myela", "engine", "today"],
            pasted: ["ship", "the", "miele", "engine", "today"])
        check(d1?.0.lowercased() == "miele" && d1?.1 == "myela", "detects miele -> myela")

        check(CorrectionListener.detectCorrection(baseline: ["the", "cat", "sat"], current: ["the", "dog", "sat"],
            pasted: ["the", "cat", "sat"]) == nil, "ignores cat -> dog rephrase")

        check(CorrectionListener.detectCorrection(baseline: ["hello", "wrold", "there"], current: ["hello", "world", "there"],
            pasted: ["hello", "there"]) == nil, "ignores fix of a word we didn't type")

        check(CorrectionListener.detectCorrection(baseline: ["aa", "bb", "cc"], current: ["xx", "bb", "yy"],
            pasted: ["aa", "bb", "cc"]) == nil, "ignores multi-word change")

        print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
    }
}
