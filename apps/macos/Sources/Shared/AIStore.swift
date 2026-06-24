import Foundation

/// memex-ai-routing — the shared, on-device model store every memex app (voz, breve, rotli…) can plug
/// into. The principle: **big model weights live once and are reused; small per-app runtimes stay local.**
///
///   ~/.memex/ai/            the shared store (override with MEMEX_AI_HOME)
///     models/<id>/          model weights — reused across apps
///   ~/.voz/                 voz's own home — venvs, server scripts, app data (Parakeet model too, if
///                           you choose "voz only"); legacy ~/.cache/sherpa is still honored
///
/// This type owns the *paths + resolution* (the standard). The download/install UX lives in the app
/// (voz's Setup). When voz reads an engine it searches **shared → app/legacy**, so a model installed once
/// to the shared store is found by every app — and a fresh app reinstall correctly *reuses* it rather than
/// re-downloading. Eventually this resolver + manifest move into memex proper (it owns the standard).
public enum AIStore {
    /// Where a new download should land. Detection always *reuses* whatever is already on the Mac; this
    /// only decides where NEW weights are written.
    public enum Target: String, CaseIterable, Identifiable {
        case shared      // ~/.memex/ai — reusable by other memex apps (the recommended default)
        case app         // ~/.voz / ~/.cache — voz only, removed when voz is removed
        public var id: String { rawValue }
        public var label: String { self == .shared ? "Shared store" : "voz only" }
    }

    /// Where a model was found, for honest Setup labels.
    public enum Origin: String {
        case shared, app, legacy
        public var label: String {
            switch self {
            case .shared: return "Shared store"
            case .app: return "voz only"
            case .legacy: return "Already on your Mac"
            }
        }
    }

    private static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    /// The shared store root — reused across memex apps. Override for tests / relocation.
    public static var sharedRoot: String {
        ProcessInfo.processInfo.environment["MEMEX_AI_HOME"] ?? "\(home)/.memex/ai"
    }
    public static var sharedModels: String { "\(sharedRoot)/models" }
    public static var appRoot: String { "\(home)/.voz" }            // voz-only runtimes + data
    public static var legacySherpaCache: String { "\(home)/.cache/sherpa" } // pre-memex model home

    /// The models dir a NEW download of `target` should write into.
    public static func modelsDir(for target: Target) -> String {
        target == .shared ? sharedModels : legacySherpaCache
    }

    // MARK: resolution (shared → app/legacy)

    /// Roots searched for an already-present sherpa/Parakeet install, in preference order.
    public static func sherpaSearchRoots() -> [String] {
        [sharedModels, "\(appRoot)/sherpa", legacySherpaCache]
    }

    /// Glob patterns (preference order) for the Parakeet model dir holding the int8 encoder.
    public static func parakeetModelGlobs() -> [String] {
        sherpaSearchRoots().map { "\($0)/*parakeet*" } + ["\(appRoot)/sherpa/model"]
    }

    /// Glob patterns (preference order) for the sherpa-onnx-offline binary.
    public static func sherpaBinGlobs() -> [String] {
        sherpaSearchRoots().map { "\($0)/*/bin/sherpa-onnx-offline" }
    }

    /// Where a present Parakeet model was found, for Setup's source label (nil = not found).
    public static func parakeetOrigin() -> Origin? {
        if globHit("\(sharedModels)/*parakeet*/encoder.int8.onnx") { return .shared }
        if FileManager.default.fileExists(atPath: "\(appRoot)/sherpa/model/encoder.int8.onnx") { return .app }
        if globHit("\(legacySherpaCache)/*parakeet*/encoder.int8.onnx") { return .legacy }
        return nil
    }

    /// Where a present MLX cleanup model was found (the warm-LLM marker holds the path it loads from).
    public static func cleanupOrigin() -> Origin? {
        guard let path = try? String(contentsOfFile: "\(appRoot)/llm-model", encoding: .utf8) else { return nil }
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.hasPrefix(sharedRoot) { return .shared }
        if p.hasPrefix(appRoot) || !p.contains("/") { return .app } // a bare HF id = cached, app-side
        return .legacy
    }

    /// Is a sherpa-onnx-offline binary already present anywhere (shared, legacy cache, or Homebrew)?
    public static func sherpaBinaryPresent() -> Bool {
        if sherpaBinGlobs().contains(where: globHit) { return true }
        return ["/opt/homebrew/bin/sherpa-onnx-offline", "/usr/local/bin/sherpa-onnx-offline"]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func globHit(_ pattern: String) -> Bool {
        var g = glob_t(); defer { globfree(&g) }
        return pattern.withCString { Darwin.glob($0, 0, nil, &g) } == 0 && g.gl_pathc > 0
    }
}
