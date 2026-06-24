import Foundation
import Shared

/// The optional on-device engines the native Setup window can install. Each one downloads its big
/// model files in-process (URLSession → real % progress) and runs only its environment step (venv /
/// bun) via a headless script — NO Terminal, no y/N prompts. State is published so the SwiftUI cards
/// reflect downloading/installed/failed live. Apple Silicon only for the model engines.
enum Engine: String, CaseIterable, Identifiable {
    case dictation, voices, cleanup
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: return "Sharper dictation"
        case .voices: return "Neural voices"
        case .cleanup: return "AI cleanup"
        }
    }
    var subtitle: String {
        switch self {
        case .dictation: return "NVIDIA Parakeet — best accuracy, on-device"
        case .voices: return "Warm, natural read-aloud (Kokoro)"
        case .cleanup: return "Punctuation + filler removal (Qwen via MLX)"
        }
    }
    var sizeText: String {
        switch self {
        case .dictation: return "~600 MB"
        case .voices: return "~90 MB"
        case .cleanup: return "~0.9 GB"
        }
    }
    var symbol: String {
        switch self {
        case .dictation: return "waveform.badge.mic"
        case .voices: return "speaker.wave.2.fill"
        case .cleanup: return "sparkles"
        }
    }
}

enum InstallState: Equatable {
    case notInstalled
    case installing(fraction: Double?, status: String) // fraction nil → indeterminate
    case installed
    case failed(String)
}

/// A snapshot of the host Mac, scanned once — chip, memory, free disk, OS — so the Setup window can
/// show what you're working with and gate engines your machine can't run (all checks are local).
struct MacInfo {
    let appleSilicon: Bool
    let chip: String
    let ramGB: Int
    let freeDiskGB: Int
    let macOS: String

    static func scan() -> MacInfo {
        var arm = Int32(0); var sz = MemoryLayout<Int32>.size
        let isArm = sysctlbyname("hw.optional.arm64", &arm, &sz, nil, 0) == 0 && arm == 1
        var chip = isArm ? "Apple Silicon" : "Intel"
        var brandLen = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &brandLen, nil, 0)
        if brandLen > 1 {
            var buf = [CChar](repeating: 0, count: brandLen)
            if sysctlbyname("machdep.cpu.brand_string", &buf, &brandLen, nil, 0) == 0 { chip = String(cString: buf) }
        }
        let ram = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        var freeGB = 0
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value {
            freeGB = Int(free / 1_073_741_824)
        }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return MacInfo(appleSilicon: isArm, chip: chip, ramGB: ram, freeDiskGB: freeGB,
                       macOS: "macOS \(v.majorVersion).\(v.minorVersion)")
    }
}

/// Drives installs and tracks state. ObservableObject so the SwiftUI window updates live.
final class EngineSetup: ObservableObject {
    static let shared = EngineSetup()

    @Published private(set) var state: [Engine: InstallState] = [:]

    /// Where NEW downloads land. Detection always *reuses* whatever is already on the Mac (any store);
    /// this only chooses where fresh weights are written — the shared memex store (reusable by Breve,
    /// Rotli, …) or voz-only. Big model weights default to shared; the small venvs/servers are always
    /// voz-local regardless.
    @Published var target: AIStore.Target = .shared

    /// A one-time scan of this Mac's capabilities — shown in the Setup window and used to gate engines.
    let mac = MacInfo.scan()
    var appleSilicon: Bool { mac.appleSilicon }

    /// Whether an engine can run on this Mac, with a short reason when it can't (shown on the card).
    func supports(_ e: Engine) -> (ok: Bool, reason: String?) {
        switch e {
        case .dictation, .cleanup: // Parakeet / MLX — Metal + headroom
            if !mac.appleSilicon { return (false, "Needs Apple Silicon") }
            if mac.ramGB < 8 { return (false, "Needs 8 GB+ RAM (have \(mac.ramGB))") }
            return (true, nil)
        case .voices: // Kokoro via bun — light
            if mac.ramGB < 4 { return (false, "Needs 4 GB+ RAM") }
            return (true, nil)
        }
    }

    private let q = DispatchQueue(label: "voz.engine.setup", qos: .userInitiated)
    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    init() { refresh() }

    // MARK: install-state detection (same paths the engines check at runtime)

    func refresh() {
        var s: [Engine: InstallState] = [:]
        for e in Engine.allCases {
            if case .installing = state[e] { s[e] = state[e]!; continue } // don't clobber an in-flight install
            s[e] = isInstalled(e) ? .installed : .notInstalled
        }
        DispatchQueue.main.async { self.state = s }
    }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    private func glob(_ pattern: String) -> Bool {
        var g = glob_t(); defer { globfree(&g) }
        return pattern.withCString { Darwin.glob($0, 0, nil, &g) } == 0 && g.gl_pathc > 0
    }

    func isInstalled(_ e: Engine) -> Bool {
        switch e {
        case .dictation: // model in any store (shared/legacy) + the voz-local warm server
            return AIStore.parakeetOrigin() != nil
                && exists("\(home)/.voz/asr-venv/bin/python3") && exists("\(home)/.voz/asr-server.py")
        case .voices:
            return exists("\(home)/.voz/kokoro/node_modules/kokoro-js")
        case .cleanup:
            return exists("\(home)/.voz/llm-venv/bin/python3") && exists("\(home)/.voz/llm-server.py")
                && exists("\(home)/.voz/llm-model")
        }
    }

    /// An honest "where it lives" label for an installed engine, for the Setup card (nil if N/A).
    func source(of e: Engine) -> String? {
        switch e {
        case .dictation: return AIStore.parakeetOrigin()?.label
        case .cleanup: return AIStore.cleanupOrigin()?.label
        case .voices: return exists("\(home)/.voz/kokoro/node_modules/kokoro-js") ? "voz only" : nil
        }
    }

    // MARK: install

    func install(_ e: Engine) {
        set(e, .installing(fraction: nil, status: "Starting…"))
        q.async {
            do {
                switch e {
                case .dictation: try self.installDictation()
                case .voices: try self.installVoices()
                case .cleanup: try self.installCleanup()
                }
                self.set(e, .installed)
            } catch {
                self.set(e, .failed(error.localizedDescription))
            }
        }
    }

    private func set(_ e: Engine, _ s: InstallState) {
        DispatchQueue.main.async { self.state[e] = s }
    }
    private func progress(_ e: Engine, _ f: Double?, _ status: String) {
        DispatchQueue.main.async { self.state[e] = .installing(fraction: f, status: status) }
    }

    // MARK: per-engine procedures

    private func installDictation() throws {
        let dest = AIStore.modelsDir(for: target) // shared store or voz-only cache
        try? FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
        let rel = "https://github.com/k2-fsa/sherpa-onnx/releases/download"
        // 1. Engine binary (~25 MB) — skip if a copy is already on the Mac (any store).
        if !AIStore.sherpaBinaryPresent() {
            try downloadAndUntar(
                URL(string: "\(rel)/v1.13.2/sherpa-onnx-v1.13.2-osx-arm64-shared.tar.bz2")!,
                into: dest, engine: .dictation, status: "Downloading engine")
        }
        // 2. Parakeet model (~482 MB) — reuse any copy already present rather than re-download.
        if AIStore.parakeetOrigin() == nil {
            try downloadAndUntar(
                URL(string: "\(rel)/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2")!,
                into: dest, engine: .dictation, status: "Downloading model")
        }
        // 3. Warm server env (venv + sherpa-onnx) — always voz-local (small, tied to the server script).
        progress(.dictation, nil, "Setting up warm server…")
        try runScript("setup-asr.sh", status: "Setting up warm server…")
    }

    private func installVoices() throws {
        try ensureBun() // Kokoro is a bun package
        progress(.voices, nil, "Installing voices…") // bun pulls kokoro-js + the model
        try runScript("setup-kokoro.sh", status: "Installing voices…")
        try? runScript("setup-kokoro-server.sh", status: "Setting up warm server…") // best-effort
    }

    /// Kokoro needs bun. Install it to ~/.bun if it isn't already somewhere standard.
    private func ensureBun() throws {
        let paths = ["\(home)/.bun/bin/bun", "/opt/homebrew/bin/bun", "/usr/local/bin/bun"]
        if paths.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return }
        progress(.voices, nil, "Installing bun runtime…")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "curl -fsSL https://bun.sh/install | bash"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard FileManager.default.isExecutableFile(atPath: "\(home)/.bun/bin/bun") else {
            throw Err.bad("could not install the bun runtime")
        }
    }

    private func installCleanup() throws {
        // 1. Environment only (venv + mlx-lm + server script). VOZ_SETUP_ENV_ONLY skips the script's
        //    own model download — we do that next in-process for real % progress.
        progress(.cleanup, nil, "Setting up runtime…")
        try runScript("setup-cleaner.sh", status: "Setting up runtime…",
                      env: ["VOZ_ASSUME_YES": "1", "VOZ_SETUP_ENV_ONLY": "1"])
        // 2. Reuse an existing model if the marker already points at one that's present.
        if let existing = try? String(contentsOfFile: "\(home)/.voz/llm-model", encoding: .utf8) {
            let p = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.isEmpty, FileManager.default.fileExists(atPath: "\(p)/config.json") { return }
        }
        // 3. Download the pinned MLX model into the chosen store (real % on the big safetensors).
        let dir = target == .shared
            ? "\(AIStore.sharedModels)/qwen2.5-1.5b-instruct-4bit"
            : "\(home)/.voz/llm/mlx-model"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try downloadMLXModel(repo: "mlx-community/Qwen2.5-1.5B-Instruct-4bit", into: dir, engine: .cleanup)
        // 4. Mark ready — the marker holds the local path the warm server loads from (fully offline).
        try dir.write(toFile: "\(home)/.voz/llm-model", atomically: true, encoding: .utf8)
    }

    // MARK: download primitives

    /// Download a Hugging Face model repo's files into `dir`. HEADs each for size so the bar is a true
    /// overall %, then downloads sequentially. The big `*.safetensors` dominates, so the bar tracks it.
    private func downloadMLXModel(repo: String, into dir: String, engine: Engine) throws {
        guard let listURL = URL(string: "https://huggingface.co/api/models/\(repo)") else { throw Err.bad("model id") }
        let meta = try getJSON(listURL)
        let files = ((meta["siblings"] as? [[String: Any]]) ?? []).compactMap { $0["rfilename"] as? String }
            .filter { !$0.hasSuffix("/") && !$0.hasPrefix(".") }
        guard !files.isEmpty else { throw Err.bad("empty model listing") }
        // Total bytes via HEAD, so % spans the whole set.
        var sizes: [String: Int64] = [:]; var total: Int64 = 0
        for f in files {
            let u = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(f)")!
            let n = contentLength(u); sizes[f] = n; total += max(0, n)
        }
        var done: Int64 = 0
        for f in files {
            let u = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(f)")!
            let dest = "\(dir)/\(f)"
            try? FileManager.default.createDirectory(
                atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let base = done
            try download(u, to: URL(fileURLWithPath: dest)) { written, _ in
                let f = total > 0 ? Double(base + written) / Double(total) : nil
                self.progress(engine, f, "Downloading model")
            }
            done += sizes[f] ?? 0
        }
    }

    private func downloadAndUntar(_ url: URL, into dir: String, engine: Engine, status: String) throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("voz-dl-\(ProcessInfo.processInfo.globallyUniqueString).tar.bz2")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try download(url, to: tmp) { written, expected in
            let f = expected > 0 ? Double(written) / Double(expected) : nil
            self.progress(engine, f, status)
        }
        progress(engine, nil, "Extracting…")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-xjf", tmp.path, "-C", dir]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Err.bad("could not extract \(url.lastPathComponent)") }
    }

    /// Synchronous URLSession download with progress (we're already off the main thread).
    private func download(_ url: URL, to dest: URL, onProgress: @escaping (Int64, Int64) -> Void) throws {
        let dl = Downloader()
        guard dl.run(url, to: dest, onProgress: onProgress) else { throw Err.bad("download failed: \(url.lastPathComponent)") }
    }

    private func getJSON(_ url: URL) throws -> [String: Any] {
        let sem = DispatchSemaphore(value: 0); var out: [String: Any] = [:]; var err: Error?
        URLSession.shared.dataTask(with: url) { data, _, e in
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { out = obj }
            err = e; sem.signal()
        }.resume()
        sem.wait()
        if let err { throw err }
        return out
    }

    private func contentLength(_ url: URL) -> Int64 {
        var req = URLRequest(url: url); req.httpMethod = "HEAD"
        let sem = DispatchSemaphore(value: 0); var len: Int64 = 0
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            len = resp?.expectedContentLength ?? 0; sem.signal()
        }.resume()
        sem.wait()
        return max(0, len)
    }

    // MARK: headless script runner

    /// Run a bundled (or repo) setup script with no Terminal and no prompts. Throws on nonzero exit.
    private func runScript(_ name: String, status: String, env extra: [String: String] = [:]) throws {
        guard let script = Self.scriptPath(name) else { throw Err.bad("missing \(name)") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script]
        var e = ProcessInfo.processInfo.environment
        e["VOZ_ASSUME_YES"] = "1"               // never prompt
        // Make user-local toolchains the script needs discoverable (bun, Homebrew python, curl).
        let extraPath = ["\(home)/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin"].joined(separator: ":")
        e["PATH"] = extraPath + ":" + (e["PATH"] ?? "/usr/bin:/bin")
        for (k, v) in extra { e[k] = v }
        p.environment = e
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        var out = Data()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue(label: "voz.script.read").async { out = pipe.fileHandleForReading.readDataToEndOfFile(); sem.signal() }
        try p.run(); p.waitUntilExit(); sem.wait()
        guard p.terminationStatus == 0 else {
            // Surface the script's last meaningful line (e.g. "python3 not found…") instead of a code.
            let tail = String(decoding: out, as: UTF8.self).split(separator: "\n").map(String.init)
                .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            throw Err.bad(tail ?? "\(name) failed (exit \(p.terminationStatus))")
        }
    }

    static func scriptPath(_ name: String) -> String? {
        let fm = FileManager.default
        if let b = Bundle.main.resourceURL?.appendingPathComponent("scripts/\(name)").path, fm.fileExists(atPath: b) { return b }
        let repo = "\(fm.homeDirectoryForCurrentUser.path)/voz/apps/macos/scripts/\(name)"
        return fm.fileExists(atPath: repo) ? repo : nil
    }

    enum Err: LocalizedError {
        case bad(String)
        var errorDescription: String? { switch self { case .bad(let m): return m } }
    }
}

/// Minimal URLSessionDownloadDelegate wrapper for a synchronous download with progress.
private final class Downloader: NSObject, URLSessionDownloadDelegate {
    private var dest: URL!
    private var onProgress: ((Int64, Int64) -> Void)?
    private let done = DispatchSemaphore(value: 0)
    private var ok = false

    func run(_ url: URL, to dest: URL, onProgress: @escaping (Int64, Int64) -> Void) -> Bool {
        self.dest = dest; self.onProgress = onProgress; self.ok = false
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session.downloadTask(with: url).resume()
        done.wait()
        session.invalidateAndCancel()
        return ok
    }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask,
                    didWriteData _: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite e: Int64) {
        onProgress?(w, e)
    }
    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didFinishDownloadingTo loc: URL) {
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: loc, to: dest)
            ok = true
        } catch { ok = false }
    }
    func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError err: Error?) {
        if err != nil { ok = false }
        done.signal()
    }
}
