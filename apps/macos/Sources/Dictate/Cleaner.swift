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
        p.standardError = Pipe()

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
    /// Helper installed -> canonical TS cleaner, else the Swift port.
    static func best() -> Cleaner {
        BunCleaner.isAvailable() ? BunCleaner() : BasicSwiftCleaner()
    }
}
