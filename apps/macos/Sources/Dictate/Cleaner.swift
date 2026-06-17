import Foundation

/// Cleanup engines are pluggable so a local-LLM cleaner (e.g. Ollama) can
/// slot in later — any future engine must stay on-device; see README.
protocol Cleaner {
    func clean(_ raw: String) -> String
}

/// Zero-setup fallback: the built-in Swift port of clean.ts.
struct BasicSwiftCleaner: Cleaner {
    func clean(_ raw: String) -> String { BasicCleaner.cleaned(raw) }
}

/// Canonical cleaner: the TypeScript helper in ~/.voz, run by bun with raw text
/// on stdin and cleaned text on stdout. Any failure or a >2s stall falls back to
/// BasicCleaner — same rules, so behavior is identical.
final class BunCleaner: Cleaner {
    /// ~/.voz (current) with a fallback to the legacy ~/.dictado, so an existing
    /// install keeps working. Whichever has clean.ts wins.
    private static var helperDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let voz = home.appendingPathComponent(".voz")
        let legacy = home.appendingPathComponent(".dictado")
        let fm = FileManager.default
        if fm.fileExists(atPath: voz.appendingPathComponent("clean.ts").path) { return voz }
        if fm.fileExists(atPath: legacy.appendingPathComponent("clean.ts").path) { return legacy }
        return voz
    }

    static func bunPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.bun/bin/bun", "/opt/homebrew/bin/bun", "/usr/local/bin/bun"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func isAvailable() -> Bool {
        bunPath() != nil && FileManager.default.fileExists(
            atPath: helperDir.appendingPathComponent("clean.ts").path)
    }

    /// Blocks up to 2s — call off the main thread.
    func clean(_ raw: String) -> String {
        guard let bun = Self.bunPath() else { return BasicCleaner.cleaned(raw) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bun)
        p.arguments = ["run", "clean.ts"]
        p.currentDirectoryURL = Self.helperDir
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice // discard stderr so a chatty helper can't fill a pipe and wedge
        defer { try? stdin.fileHandleForWriting.close() } // ensure the write end is released on every path

        do {
            try p.run()
            stdin.fileHandleForWriting.write(Data(raw.utf8))
            stdin.fileHandleForWriting.closeFile()
        } catch {
            return BasicCleaner.cleaned(raw)
        }

        var output = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            output = stdout.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            done.signal()
        }
        guard done.wait(timeout: .now() + 2) == .success else {
            // Same escalation as Subprocess.run: SIGTERM, then SIGKILL if it lingers, so a wedged
            // bun is never orphaned and the reader thread is reclaimed. Then fall back to the Swift port.
            if p.isRunning { p.terminate() }
            if done.wait(timeout: .now() + 1) != .success {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                _ = done.wait(timeout: .now() + 1)
            }
            return BasicCleaner.cleaned(raw)
        }
        guard p.terminationStatus == 0 else { return BasicCleaner.cleaned(raw) }

        let cleaned = String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? BasicCleaner.cleaned(raw) : cleaned
    }
}

enum Cleaners {
    /// The on-device "polish with AI" toggle. On by default, but it only does
    /// anything once an open-weight model is installed (scripts/setup-cleaner.sh);
    /// until then `best()` returns the deterministic cleaner regardless.
    static var llmEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "llmCleanupEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "llmCleanupEnabled") }
    }

    /// Best available cleaner. With the AI layer on, the on-device LLM polishes the
    /// text (always wrapping the deterministic cleaner as its fallback): a local
    /// Ollama you already run is preferred (warm, shared with your other tools),
    /// else a self-contained llama.cpp model. Otherwise: helper installed ->
    /// canonical TS cleaner, else the Swift port.
    ///
    /// NOTE: probes the network/disk, so call OFF the main thread.
    static func best() -> Cleaner { select(useLLM: llmEnabled) }

    /// Like `best()`, but skips the LLM entirely when `raw` is already clean — saving the polish
    /// latency on dictations that don't need it. Use this on the live paste path.
    static func best(for raw: String) -> Cleaner { select(useLLM: llmEnabled && LLMPolish.worthRunning(raw)) }

    private static func select(useLLM: Bool) -> Cleaner {
        let base: Cleaner = BunCleaner.isAvailable() ? BunCleaner() : BasicSwiftCleaner()
        guard useLLM else { return base }
        if OllamaCleaner.isInstalled() { return OllamaCleaner(fallback: base) }  // warm, shared (e.g. Breve)
        if LLMCleaner.isAvailable() { return LLMCleaner(fallback: base) }        // self-contained llama.cpp
        return base
    }
}
