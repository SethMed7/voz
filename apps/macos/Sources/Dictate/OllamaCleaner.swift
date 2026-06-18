import Foundation

/// Preferred polish backend: reuse a local Ollama you already run (the same
/// runtime tools like Breve use) so a model is never installed in two places.
/// Ollama keeps the model warm, so there's no per-clip reload. 100% on-device.
///
/// Talks to the local server with `curl` via `Subprocess` — the same shell-out
/// pattern every other engine here uses (afconvert, whisper, sherpa, bun). That
/// sidesteps URLSession's cleartext-HTTP/ATS and no-runloop pitfalls for a
/// loopback service, and keeps one bounded-timeout, kill-on-stall code path.
///
/// Pluggable + guarded: any failure (server down, or output that changed your
/// words) falls back to the deterministic cleaner.
final class OllamaCleaner: Cleaner {
    private let fallback: Cleaner
    init(fallback: Cleaner) { self.fallback = fallback }

    /// Base URL of the local server: $OLLAMA_HOST (normalized) or the default. PRIVACY: voz only ever
    /// talks to a LOCAL Ollama — if OLLAMA_HOST points anywhere non-loopback, we ignore it so your
    /// transcript text can never leave the machine (the "100% on-device" promise is enforced, not assumed).
    static func host() -> String {
        var h = ProcessInfo.processInfo.environment["OLLAMA_HOST"] ?? "127.0.0.1:11434"
        if !h.contains("://") { h = "http://" + h }
        if let host = URL(string: h)?.host, !isLoopback(host) { return "http://127.0.0.1:11434" }
        return h
    }

    private static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "127.0.0.1" || h == "localhost" || h == "::1" || h == "[::1]"
    }

    /// Cheap, no-network check for the menu: is the ollama binary installed (or a host configured)?
    /// Whether the server is actually up is settled at clean-time, which falls back if it isn't.
    static func isInstalled() -> Bool {
        if ProcessInfo.processInfo.environment["OLLAMA_HOST"] != nil { return true }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return Subprocess.firstExecutable([
            "/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "\(home)/.local/bin/ollama",
        ]) != nil
    }

    /// The model to use: VOZ_OLLAMA_MODEL → the first model the server reports, cached so we don't
    /// curl /api/tags on every clean (warm() primes this during recording). Call OFF the main thread.
    private static var cachedModel: String?
    private static let modelLock = NSLock() // warm() and clean() reach model() from two concurrent off-main dispatches
    static func model() -> String? {
        if let m = ProcessInfo.processInfo.environment["VOZ_OLLAMA_MODEL"], !m.isEmpty { return m }
        modelLock.lock(); let cached = cachedModel; modelLock.unlock()
        if let cached { return cached }
        let fetched = tags()?.first // network call OUTSIDE the lock (don't block the other caller ~4s)
        modelLock.lock(); if cachedModel == nil { cachedModel = fetched }; let result = cachedModel; modelLock.unlock()
        return result
    }

    private static func curlPath() -> String {
        Subprocess.firstExecutable(["/usr/bin/curl", "/opt/homebrew/bin/curl"]) ?? "/usr/bin/curl"
    }

    private static func tags() -> [String]? {
        guard let r = Subprocess.run(curlPath(), ["-s", "--max-time", "2", "\(host())/api/tags"], timeout: 4),
              r.status == 0,
              let obj = try? JSONSerialization.jsonObject(with: r.stdout) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else { return nil }
        let names = models.compactMap { $0["name"] as? String }
        return names.isEmpty ? nil : names
    }

    /// Fire-and-forget preload so the first dictation isn't slowed by a cold model load. Called when
    /// you start recording, so the ~seconds-long load overlaps with you speaking. Call OFF the main thread.
    static func warm() {
        guard let model = model() else { return }
        let body: [String: Any] = ["model": model, "stream": false, "keep_alive": "30m",
                                    "think": false, "prompt": "hi", "options": ["num_predict": 1]]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("voz-warm-\(ProcessInfo.processInfo.globallyUniqueString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? data.write(to: tmp)) != nil else { return }
        _ = Subprocess.run(curlPath(), ["-s", "--max-time", "60", "-X", "POST", "\(host())/api/generate",
                                        "-H", "Content-Type: application/json", "-d", "@\(tmp.path)"], timeout: 63)
    }

    /// Blocks on the local server — call OFF the main thread (DictateController does, on a utility queue).
    func clean(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback.clean(raw) }
        guard let model = Self.model() else { return fallback.clean(raw) }

        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "keep_alive": "30m",                 // hold the model warm between dictations
            "think": false,                      // skip reasoning traces — they make a thinking model ~50× slower
            "options": ["temperature": 0, "num_predict": 1024], // deterministic, bounded
            "messages": [
                ["role": "system", "content": LLMPolish.systemPrompt],
                ["role": "user", "content": trimmed],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return fallback.clean(raw) }
        // Pass the body via a temp file (-d @file) — avoids arg-length/escaping limits.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("voz-ollama-\(ProcessInfo.processInfo.globallyUniqueString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? data.write(to: tmp)) != nil else { return fallback.clean(raw) }

        // Warm Ollama answers in ~1s; scale modestly with length and keep a sane floor (not 30s).
        let secs = Int(max(10, Double(trimmed.count) / 12 + 6))
        let args = ["-s", "--max-time", "\(secs)", "-X", "POST", "\(Self.host())/api/chat",
                    "-H", "Content-Type: application/json", "-d", "@\(tmp.path)"]
        guard let r = Subprocess.run(Self.curlPath(), args, timeout: TimeInterval(secs) + 3), r.status == 0,
              let obj = try? JSONSerialization.jsonObject(with: r.stdout) as? [String: Any],
              let msg = obj["message"] as? [String: Any],
              let content = msg["content"] as? String else { return fallback.clean(raw) }
        let out = LLMPolish.clip(content)
        return LLMPolish.accept(out, against: trimmed) ? out : fallback.clean(raw)
    }
}
