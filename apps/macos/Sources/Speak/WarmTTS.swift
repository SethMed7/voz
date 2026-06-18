import Foundation

/// Manages voz's warm Kokoro TTS server (core/say-server.ts, installed beside say.ts by
/// scripts/setup-kokoro-server.sh). It keeps the model loaded so each read skips the ~1-2s per-spawn
/// reload the one-shot say.ts pays — same model + voices, just resident. Binds 127.0.0.1 ONLY.
///
/// Optional + graceful: if bun / the script / kokoro-js aren't present, everything no-ops and voz
/// uses the cold per-spawn say.ts path (KokoroEngine falls back). A server left running from a prior
/// session is detected (health check) and reused, so warmth persists across restarts. `ready` is a
/// cheap cached flag the audio engine reads on the main thread to pick warm-vs-cold without blocking.
final class WarmTTS {
    static let shared = WarmTTS()

    let port = ProcessInfo.processInfo.environment["VOZ_TTS_PORT"] ?? "8766"
    private var server: Process?
    private let lock = NSLock()

    /// Cached health, updated by prewarm() off the main thread; read cheaply on main by KokoroEngine.
    private(set) var ready = false
    private var lastHealthyAt = Date.distantPast  // skip the probe on rapid re-arms when recently healthy

    var baseURL: String { "http://127.0.0.1:\(port)" }

    private static func home() -> String { FileManager.default.homeDirectoryForCurrentUser.path }

    /// Where say-server.ts + kokoro-js live: ~/.voz/kokoro (current) else ~/.leelo (legacy) — matches
    /// KokoroEngine.helperDir so the server runs with kokoro-js resolvable.
    static func helperDir() -> String {
        let home = home()
        let voz = "\(home)/.voz/kokoro", legacy = "\(home)/.leelo"
        let fm = FileManager.default
        if fm.fileExists(atPath: "\(voz)/node_modules/kokoro-js") { return voz }
        if fm.fileExists(atPath: "\(legacy)/node_modules/kokoro-js") { return legacy }
        return voz
    }
    static func scriptPath() -> String? {
        let p = "\(helperDir())/say-server.ts"
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }
    static func bunPath() -> String? {
        firstExecutable(["\(home())/.bun/bin/bun", "/opt/homebrew/bin/bun", "/usr/local/bin/bun"])
    }
    /// Installed = bun + the server script + kokoro-js all present.
    static func isInstalled() -> Bool {
        bunPath() != nil && scriptPath() != nil
            && FileManager.default.fileExists(atPath: "\(helperDir())/node_modules/kokoro-js")
    }

    static func curlPath() -> String {
        firstExecutable(["/usr/bin/curl", "/opt/homebrew/bin/curl"]) ?? "/usr/bin/curl"
    }

    // Small self-contained process helpers — Subprocess lives in the Dictate module, and Speak
    // shouldn't depend on it, so WarmTTS carries its own tiny copies.
    private static func firstExecutable(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    private static func run(_ exe: String, _ args: [String], timeout: TimeInterval) -> (status: Int32, stdout: Data)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        var data = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); done.signal()
        }
        if done.wait(timeout: .now() + timeout) != .success {
            if p.isRunning { p.terminate() }
            _ = done.wait(timeout: .now() + 1)
            return nil
        }
        return (p.terminationStatus, data)
    }

    func isHealthy() -> Bool {
        guard let r = Self.run(Self.curlPath(), ["-s", "--max-time", "1", "\(baseURL)/health"], timeout: 2),
              r.status == 0, let s = String(data: r.stdout, encoding: .utf8) else { return false }
        return s.contains("\"ok\"")
    }

    /// Start the server if installed and not already healthy (reusing any prior instance), then poll
    /// until it answers /health (the one-time model load is ~1-2s). Idempotent. Call OFF the main
    /// thread. Updates `ready` so the audio engine can pick the warm path on the main thread.
    func prewarm() {
        guard Self.isInstalled() else { ready = false; return }
        if ready, Date().timeIntervalSince(lastHealthyAt) < 30 { return } // trust the cache — no curl probe
        if isHealthy() { ready = true; lastHealthyAt = Date(); return } // a prior session's server is up — reuse it
        lock.lock()
        if server == nil || server?.isRunning != true, !isHealthy(),
           let bun = Self.bunPath(), let script = Self.scriptPath() {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bun)
            p.arguments = ["run", script]
            p.currentDirectoryURL = URL(fileURLWithPath: Self.helperDir())
            var env = ProcessInfo.processInfo.environment
            env["VOZ_TTS_PORT"] = port
            p.environment = env
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            server = (try? p.run()) != nil ? p : nil
        }
        lock.unlock()
        ready = waitHealthy(timeout: 12)
        if ready { lastHealthyAt = Date() }
    }

    /// A warm request just failed — re-verify health on the next read rather than trusting the cache.
    func markStale() { ready = false }

    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        if let s = server, s.isRunning { s.terminate() }
        server = nil
        ready = false
    }

    private func waitHealthy(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat { if isHealthy() { return true }; usleep(200_000) } while Date() < deadline
        return false
    }
}
