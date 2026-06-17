import Foundation

/// Manages voz's warm Parakeet ASR server (core/asr-server.py in a venv, installed by
/// scripts/setup-asr.sh). It keeps the model loaded so each clip transcribes in ~0.08s over
/// loopback HTTP instead of the ~1.5s a cold sherpa CLI spawn costs — same model, same quality.
///
/// Optional + graceful: if the venv/script/model aren't present, everything no-ops and voz uses the
/// cold transcription chain. A server left running from a previous voz session is detected (health
/// check) and reused, so warmth persists across restarts.
final class WarmASR {
    static let shared = WarmASR()

    private let port = ProcessInfo.processInfo.environment["VOZ_ASR_PORT"] ?? "8765"
    private var server: Process?
    private let lock = NSLock()

    private static func home() -> String { FileManager.default.homeDirectoryForCurrentUser.path }
    static func venvPython() -> String? { Subprocess.firstExecutable(["\(home())/.voz/asr-venv/bin/python3"]) }
    static func scriptPath() -> String? {
        let p = "\(home())/.voz/asr-server.py"
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }
    /// Installed = venv python + the server script + the Parakeet model all present.
    static func isInstalled() -> Bool {
        venvPython() != nil && scriptPath() != nil && SherpaTranscriber.modelDir() != nil
    }

    private var baseURL: String { "http://127.0.0.1:\(port)" }
    private func curl() -> String { Subprocess.firstExecutable(["/usr/bin/curl", "/opt/homebrew/bin/curl"]) ?? "/usr/bin/curl" }

    /// Start the server if installed and not already healthy (reusing any prior instance). Idempotent;
    /// the model loads in the child (~1.1s). Call OFF the main thread.
    func ensureRunning() {
        guard Self.isInstalled(), !isHealthy() else { return }
        lock.lock(); defer { lock.unlock() }
        if let s = server, s.isRunning { return }
        if isHealthy() { return } // a prior session's server is already up — reuse it
        guard let py = Self.venvPython(), let script = Self.scriptPath() else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        p.arguments = [script]
        var env = ProcessInfo.processInfo.environment
        env["VOZ_ASR_PORT"] = port
        if let model = SherpaTranscriber.modelDir() { env["VOZ_PARAKEET_MODEL"] = model }
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        server = (try? p.run()) != nil ? p : nil
    }

    func isHealthy() -> Bool {
        guard let r = Subprocess.run(curl(), ["-s", "--max-time", "1", "\(baseURL)/health"], timeout: 2),
              r.status == 0, let s = String(data: r.stdout, encoding: .utf8) else { return false }
        return s.contains("\"ok\"")
    }

    /// Transcribe a 16k-mono WAV via the warm server. nil if unavailable/failed → caller falls back
    /// to the cold chain. Call OFF the main thread.
    func transcribe(wav16kPath: String) -> String? {
        guard Self.isInstalled() else { return nil }
        ensureRunning()
        guard waitHealthy(timeout: 8) else { return nil } // first call waits out the one-time model load
        let body = "{\"path\":\"\(wav16kPath)\"}"
        guard let r = Subprocess.run(curl(), ["-s", "--max-time", "15", "-X", "POST",
              "\(baseURL)/transcribe", "-H", "Content-Type: application/json", "-d", body], timeout: 18),
              r.status == 0,
              let obj = try? JSONSerialization.jsonObject(with: r.stdout) as? [String: Any],
              let text = obj["text"] as? String else { return nil }
        return text
    }

    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        if let s = server, s.isRunning { s.terminate() }
        server = nil
    }

    private func waitHealthy(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat { if isHealthy() { return true }; usleep(200_000) } while Date() < deadline
        return false
    }
}
