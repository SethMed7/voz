import Foundation

/// Manages voz's warm MLX LLM polish server (core/llm-server.py in a venv, installed by
/// scripts/setup-cleaner.sh). Keeps a small instruct model (Qwen2.5-1.5B-Instruct) loaded so each
/// polish runs in well under a second over loopback HTTP instead of paying a per-clip model reload —
/// the same warm-server pattern as WarmASR. Apple Silicon only (MLX).
///
/// Optional + graceful: if the venv/script/model aren't present, everything no-ops and the cleaner
/// chain falls back. A server left running from a previous voz session is detected (health check) and
/// reused, so warmth persists across restarts. PRIVACY: spawned with HF_HUB_OFFLINE=1, so it can never
/// reach the network at dictation time — only the weights you approved at setup are ever used.
final class WarmLLM {
    static let shared = WarmLLM()

    private let port = ProcessInfo.processInfo.environment["VOZ_LLM_PORT"] ?? "8766"
    private var server: Process?
    private let lock = NSLock()

    private static func home() -> String { FileManager.default.homeDirectoryForCurrentUser.path }
    static func venvPython() -> String? { Subprocess.firstExecutable(["\(home())/.voz/llm-venv/bin/python3"]) }
    static func scriptPath() -> String? {
        let p = "\(home())/.voz/llm-server.py"
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }
    /// A marker dropped by setup-cleaner.sh once the model is downloaded with your consent. The server
    /// runs offline, so without cached weights its first load would fail — gating on this keeps the
    /// warm path dark until the download actually happened.
    static func modelReady() -> Bool {
        FileManager.default.fileExists(atPath: "\(home())/.voz/llm-model")
    }
    /// Installed = venv python + the server script + a consented model download.
    static func isInstalled() -> Bool {
        venvPython() != nil && scriptPath() != nil && modelReady()
    }

    private var baseURL: String { "http://127.0.0.1:\(port)" }
    private func curl() -> String { Subprocess.firstExecutable(["/usr/bin/curl", "/opt/homebrew/bin/curl"]) ?? "/usr/bin/curl" }

    /// Start the server if installed and not already healthy (reusing any prior instance). Idempotent;
    /// the model loads in the child (~1-2s). Call OFF the main thread.
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
        env["VOZ_LLM_PORT"] = port
        env["HF_HUB_OFFLINE"] = "1"            // never reach the network at dictation time
        env["TOKENIZERS_PARALLELISM"] = "false"
        // The marker holds the model to load: a local dir (native Setup install → fully offline) or an
        // HF repo id (shell install → from the HF cache). An explicit env var still wins.
        if let raw = try? String(contentsOfFile: "\(Self.home())/.voz/llm-model", encoding: .utf8) {
            let m = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !m.isEmpty { env["VOZ_LLM_MODEL"] = m }
        }
        if let m = ProcessInfo.processInfo.environment["VOZ_LLM_MODEL"], !m.isEmpty { env["VOZ_LLM_MODEL"] = m }
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

    /// Polish `text` with `system` as the instruction, via the warm server. nil if unavailable/failed
    /// → caller falls back to the deterministic cleaner. Call OFF the main thread. `timeout` bounds the
    /// request; the first call also waits out the one-time model load.
    func clean(system: String, text: String, timeout: TimeInterval) -> String? {
        guard Self.isInstalled() else { return nil }
        ensureRunning()
        guard waitHealthy(timeout: 15) else { return nil } // first call waits out the one-time model load
        // Polish output is ~the input length, so cap generation near it (≈chars/3 tokens + headroom)
        // instead of a flat 1024 — the model can't ramble, which is the dominant cost on long dictations.
        let maxTokens = max(96, min(1024, text.count / 3 + 64))
        let body: [String: Any] = ["system": system, "text": text, "max_tokens": maxTokens]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        // Pass the body via a temp file (-d @file) — avoids arg-length/escaping limits.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("voz-llm-\(ProcessInfo.processInfo.globallyUniqueString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? data.write(to: tmp)) != nil else { return nil }
        let args = ["-s", "--max-time", "\(Int(timeout))", "-X", "POST", "\(baseURL)/clean",
                    "-H", "Content-Type: application/json", "-d", "@\(tmp.path)"]
        guard let r = Subprocess.run(curl(), args, timeout: timeout + 3), r.status == 0,
              let obj = try? JSONSerialization.jsonObject(with: r.stdout) as? [String: Any],
              let out = obj["text"] as? String else { return nil }
        return out
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
