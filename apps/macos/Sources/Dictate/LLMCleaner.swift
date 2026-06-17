import Foundation

/// Fallback polish backend for machines with no Ollama: a small open-weight
/// instruct model (Qwen2.5-Instruct by default, Apache-2.0) run via llama.cpp,
/// installed by scripts/setup-cleaner.sh into ~/.voz/llm. Same idea as Ollama —
/// add punctuation + drop contextual fillers, 100% on-device — but self-contained.
///
/// Same shape as the transcription engines: detect a binary + model on disk,
/// shell out with a bounded timeout, and fall back (via the shared guard) on any
/// failure. The model loads per spawn (~1–2s for 1.5B on Metal); prefer Ollama
/// (warm, no reload) when present — `Cleaners.best()` does.
final class LLMCleaner: Cleaner {
    private let fallback: Cleaner

    init(fallback: Cleaner) { self.fallback = fallback }

    // MARK: discovery

    static func binaryPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            ProcessInfo.processInfo.environment["VOZ_LLAMA_BIN"],
            "\(home)/.voz/llm/bin/llama-cli",
            "/opt/homebrew/bin/llama-cli",
            "/usr/local/bin/llama-cli",
            "\(home)/.local/bin/llama-cli",
        ].compactMap { $0 }
        return Subprocess.firstExecutable(candidates)
    }

    /// A single .gguf model. VOZ_LLM_MODEL overrides; otherwise the file the
    /// setup script drops at ~/.voz/llm/model.gguf.
    static func modelPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            ProcessInfo.processInfo.environment["VOZ_LLM_MODEL"],
            "\(home)/.voz/llm/model.gguf",
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    static func isAvailable() -> Bool { binaryPath() != nil && modelPath() != nil }

    // MARK: clean

    /// Blocks while llama.cpp runs — call OFF the main thread (DictateController does).
    func clean(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback.clean(raw) }
        guard let bin = Self.binaryPath(), let model = Self.modelPath() else { return fallback.clean(raw) }

        // ChatML (Qwen2.5). A non-ChatML model swapped in via VOZ_LLM_MODEL would
        // need its own template; the guard below still keeps a mismatch safe.
        let prompt = "<|im_start|>system\n\(LLMPolish.systemPrompt)<|im_end|>\n<|im_start|>user\n\(trimmed)<|im_end|>\n<|im_start|>assistant\n"

        // Greedy (temp 0) for determinism; GPU-offload for speed; logs to stderr
        // (Subprocess discards them) so stdout is the completion only.
        let args = [
            "-m", model, "-no-cnv", "--no-display-prompt",
            "-c", "4096", "-n", "512", "--temp", "0", "-ngl", "99", "-t", "4",
            "-p", prompt,
        ]
        let timeout = max(8, Double(trimmed.count) / 20 + 8)
        guard let r = Subprocess.run(bin, args, timeout: timeout), r.status == 0 else {
            return fallback.clean(raw)
        }
        let out = LLMPolish.clip(String(decoding: r.stdout, as: UTF8.self))
        return LLMPolish.accept(out, against: trimmed) ? out : fallback.clean(raw)
    }
}
