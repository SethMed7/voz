import AVFoundation
import AppKit

enum SpeakerState {
    case preparing
    case speaking
    case paused
    case done
    case failed(String)
}

protocol SpeechEngine: AnyObject {
    /// `onWord` reports the character range (UTF-16, within `text`) currently
    /// being spoken, so the UI can highlight it as a read-along marker.
    func speak(_ text: String, onState: @escaping (SpeakerState) -> Void, onWord: @escaping (NSRange) -> Void)
    func pause()
    func resume()
    func stop()
}

/// Collapse runs of whitespace to single spaces so the text we display, speak,
/// and highlight all line up in the same character coordinates.
func normalizeSpeech(_ s: String) -> String {
    s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Word (non-whitespace run) ranges within a string, in UTF-16 coordinates so
/// they map straight onto NSTextView/NSRange.
func wordRanges(in s: String) -> [NSRange] {
    let ns = s as NSString
    var ranges: [NSRange] = []
    var i = 0
    let n = ns.length
    while i < n {
        while i < n, isSpace(ns.character(at: i)) { i += 1 }
        let start = i
        while i < n, !isSpace(ns.character(at: i)) { i += 1 }
        if i > start { ranges.append(NSRange(location: start, length: i - start)) }
    }
    return ranges
}
private func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0D }

/// Facade the UI talks to. Holds the full list of captured selections for the
/// session (so the read-along panel keeps them all visible) and plays them in
/// order; picks Kokoro when the optional helper is installed, else the built-in
/// macOS voice.
final class Speaker {
    static let shared = Speaker()

    var voiceId: String {
        get { UserDefaults.standard.string(forKey: "voiceId") ?? "af_heart" }
        set { UserDefaults.standard.set(newValue, forKey: "voiceId") }
    }

    /// Called on the main thread once the last queued selection finishes.
    var onQueueDrained: (() -> Void)?

    private var current: SpeechEngine?
    private var next: KokoroEngine?        // one selection prefetched ahead (Kokoro only — no gap to hide for system voice)
    private var nextIndex = -1
    private var nextFailed = false
    private(set) var isPaused = false
    private var segments: [String] = []   // every selection this session, kept for the transcript
    private var playIndex = 0             // index of the selection currently playing / next up
    private var active = false

    /// Selections still waiting (not counting the one playing).
    var pending: Int { max(0, segments.count - playIndex - (active ? 1 : 0)) }
    var isActive: Bool { active }

    /// Append a highlighted selection (capture mode). Starts playback if idle; otherwise begins
    /// rendering it in the background so it's ready to play the moment the current one ends.
    func enqueue(_ text: String) {
        let norm = Pronouncer.shared.apply(normalizeSpeech(text)) // say learned words the way you mean
        guard !norm.isEmpty else { return }
        if !mergeIntoLast(norm) { // a cut-off word finished → joined onto the last selection instead
            segments.append(norm)
            Overlay.shared.addSegment(norm)
        }
        if !active { playFrom() } else { prefetchNext() }
    }

    /// Tiny reasoning: if the last (still-pending) selection ends mid-word and this one continues it
    /// lowercase ("inter" then "net"), join them into one word rather than reading them apart.
    private func mergeIntoLast(_ norm: String) -> Bool {
        guard active, let last = segments.indices.last, last > playIndex else { return false }
        guard let prevLast = segments[last].unicodeScalars.last, let newFirst = norm.unicodeScalars.first,
              CharacterSet.letters.contains(prevLast), CharacterSet.lowercaseLetters.contains(newFirst) else { return false }
        segments[last] += norm
        Overlay.shared.appendToLastSegment(norm)
        if last == nextIndex { next?.stop(); next = nil; nextIndex = -1; nextFailed = false; prefetchNext() } // redo stale prefetch
        return true
    }

    /// Click-to-skip from the transcript: jump playback to the given selection.
    func jumpTo(segment index: Int) {
        guard index >= 0, index < segments.count else { return }
        stopEngines()
        isPaused = false
        playIndex = index
        playFrom()
    }

    /// One-shot read: replace the session with a single selection (Services / menu).
    func speakNow(_ text: String) {
        stopEngines()
        active = false
        playIndex = 0
        segments = [Pronouncer.shared.apply(normalizeSpeech(text))]
        Overlay.shared.clearTranscript()
        Overlay.shared.addSegment(segments[0])
        playFrom()
    }

    /// Switching voice mid-read re-renders the current selection (and re-prefetches) in the new voice.
    func setVoice(_ id: String) {
        voiceId = id
        next?.stop(); next = nil; nextIndex = -1; nextFailed = false // a prefetch in the old voice is stale
        if active, playIndex < segments.count { playLive(segments[playIndex], index: playIndex); prefetchNext() }
    }

    func toggle() {
        guard let current else { return }
        if isPaused { current.resume(); isPaused = false }
        else { current.pause(); isPaused = true }
    }

    /// Hard stop: clear the session and tear down both engines.
    func stop() {
        stopEngines()
        segments.removeAll()
        playIndex = 0
        isPaused = false
        active = false
    }

    private func stopEngines() {
        current?.stop(); current = nil
        next?.stop(); next = nil; nextIndex = -1; nextFailed = false
    }

    /// Play the selection at `playIndex`, promoting a ready prefetch when one exists (gapless),
    /// or signal the queue is drained.
    private func playFrom() {
        guard playIndex < segments.count else {
            active = false
            Overlay.shared.setActiveSegment(-1)
            onQueueDrained?()
            return
        }
        active = true
        isPaused = false
        Overlay.shared.setActiveSegment(playIndex)
        if let n = next, nextIndex == playIndex, !nextFailed {
            // Already buffering in the background → start instantly, no "preparing" gap.
            current = n
            next = nil; nextIndex = -1
            n.beginPlayback()
        } else {
            next?.stop(); next = nil; nextIndex = -1; nextFailed = false
            playLive(segments[playIndex], index: playIndex) // the proven path; also the fallback
        }
        prefetchNext()
    }

    private func playLive(_ text: String, index: Int) {
        let useKokoro = voiceId != "system" && KokoroEngine.isAvailable()
        let engine: SpeechEngine = useKokoro ? KokoroEngine() : SystemEngine()
        current = engine
        engine.speak(text, onState: { [weak self] s in self?.handleState(engine, index, s) },
                           onWord: { [weak self] r in self?.handleWord(engine, index, r) })
    }

    /// Render the selection after the one playing, ahead of time, without playing it yet.
    private func prefetchNext() {
        guard voiceId != "system", KokoroEngine.isAvailable() else { return } // system voice has no gap
        let i = playIndex + 1
        guard i < segments.count, nextIndex != i else { return }
        next?.stop()
        nextFailed = false
        let e = KokoroEngine()
        next = e; nextIndex = i
        e.prepare(segments[i], onState: { [weak self] s in self?.handleState(e, i, s) },
                              onWord: { [weak self] r in self?.handleWord(e, i, r) })
    }

    /// State from an engine. Only the CURRENT engine drives the UI and advances the queue; a
    /// prefetching engine just buffers (and flags itself failed so we fall back to a live render).
    private func handleState(_ engine: SpeechEngine, _ index: Int, _ state: SpeakerState) {
        DispatchQueue.main.async {
            if let n = self.next, engine === n {
                if case .failed = state { self.nextFailed = true }
                return
            }
            guard let cur = self.current, engine === cur else { return } // stale engine
            Overlay.shared.update(state: state)
            switch state {
            case .paused: self.isPaused = true
            case .speaking, .preparing: self.isPaused = false
            // Both finish states advance: a failed item is skipped, not left to wedge the queue.
            case .done, .failed:
                self.current = nil
                engine.stop()
                self.playIndex += 1
                self.playFrom()
            }
        }
    }

    private func handleWord(_ engine: SpeechEngine, _ index: Int, _ range: NSRange) {
        DispatchQueue.main.async {
            guard let cur = self.current, engine === cur else { return }
            Overlay.shared.highlightWord(segment: index, range: range)
        }
    }
}

// MARK: - Built-in macOS voice (zero setup, works for every download)

final class SystemEngine: NSObject, SpeechEngine, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var onState: ((SpeakerState) -> Void)?
    private var onWord: ((NSRange) -> Void)?

    func speak(_ text: String, onState: @escaping (SpeakerState) -> Void, onWord: @escaping (NSRange) -> Void) {
        self.onState = onState
        self.onWord = onWord
        synth.delegate = self
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        onState(.speaking)
        synth.speak(utterance)
    }

    func pause() {
        synth.pauseSpeaking(at: .word)
        onState?(.paused)
    }

    func resume() {
        synth.continueSpeaking()
        onState?(.speaking)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
    }

    // Exact word-by-word range as each word is about to be spoken.
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        onWord?(characterRange)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onState?(.done)
    }
}

// MARK: - Kokoro voice (optional helper in ~/.voz/kokoro, rendered by bun + kokoro-js)

final class KokoroEngine: NSObject, SpeechEngine, AVAudioPlayerDelegate {
    /// Where the Kokoro helper lives: ~/.voz/kokoro (current), falling back to the legacy
    /// ~/.leelo so an existing install keeps working untouched. Whichever actually has the
    /// helper installed wins; a fresh install lands in ~/.voz/kokoro.
    private static var helperDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let voz = home.appendingPathComponent(".voz/kokoro")
        let legacy = home.appendingPathComponent(".leelo")
        let fm = FileManager.default
        if fm.fileExists(atPath: voz.appendingPathComponent("node_modules/kokoro-js").path) { return voz }
        if fm.fileExists(atPath: legacy.appendingPathComponent("node_modules/kokoro-js").path) { return legacy }
        return voz
    }

    static func bunPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.bun/bin/bun", "/opt/homebrew/bin/bun", "/usr/local/bin/bun"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func isAvailable() -> Bool {
        bunPath() != nil && FileManager.default.fileExists(
            atPath: helperDir.appendingPathComponent("node_modules/kokoro-js").path)
    }

    private var process: Process?
    private var stdoutHandle: FileHandle?
    private var queue: [(url: URL, text: String)] = []
    private var player: AVAudioPlayer?
    private var rendererDone = false
    private var stopped = false
    private var onState: ((SpeakerState) -> Void)?
    private var onWord: ((NSRange) -> Void)?

    // Karaoke bookkeeping: where in the segment the current chunk sits, and a
    // timer that walks the word highlight across the chunk's audio duration.
    private var segment: NSString = ""
    private var searchOffset = 0
    private var chunkOffset = 0
    private var chunkWords: [NSRange] = []
    private var wordTimer: Timer?
    private var lastWordIndex = -1
    private var autoplay = true // false while prefetching: buffer chunks, don't play until promoted

    func speak(_ text: String, onState: @escaping (SpeakerState) -> Void, onWord: @escaping (NSRange) -> Void) {
        autoplay = true
        begin(text, onState: onState, onWord: onWord)
    }

    /// Render ahead WITHOUT playing — chunks buffer until beginPlayback() promotes this engine.
    /// Lets the next selection's audio be ready the instant the current one ends (gapless).
    func prepare(_ text: String, onState: @escaping (SpeakerState) -> Void, onWord: @escaping (NSRange) -> Void) {
        autoplay = false
        begin(text, onState: onState, onWord: onWord)
    }

    /// Promote a prepared engine to active playback (its chunks are already buffering).
    func beginPlayback() {
        autoplay = true
        if player == nil { playNext() }
    }

    private func begin(_ text: String, onState: @escaping (SpeakerState) -> Void, onWord: @escaping (NSRange) -> Void) {
        self.onState = onState
        self.onWord = onWord
        self.segment = text as NSString
        self.searchOffset = 0
        onState(.preparing)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.bunPath()!)
        p.arguments = ["run", "say.ts"]
        p.currentDirectoryURL = Self.helperDir
        var env = ProcessInfo.processInfo.environment
        env["VOZ_VOICE"] = Speaker.shared.voiceId
        env["LEELO_VOICE"] = Speaker.shared.voiceId // keep a legacy ~/.leelo say.ts working too
        p.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr

        let outHandle = stdout.fileHandleForReading
        stdoutHandle = outHandle
        var buffer = Data()
        outHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // EOF (helper exited): tear the handler down or it busy-loops a CPU core forever.
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            buffer.append(data)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[..<nl], as: UTF8.self)
                buffer.removeSubrange(...nl)
                guard line.hasPrefix("/") else { continue }
                // "<path>\t<chunk text>" — chunk text is optional (older helper).
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                let path = parts[0].trimmingCharacters(in: .whitespaces)
                let chunk = parts.count > 1 ? String(parts[1]) : ""
                DispatchQueue.main.async { self?.enqueue(URL(fileURLWithPath: path), text: chunk) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                self.rendererDone = true
                if proc.terminationStatus != 0 && self.queue.isEmpty && self.player == nil {
                    let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    self.onState?(.failed(String(err.suffix(200))))
                } else if self.player == nil && self.queue.isEmpty {
                    self.onState?(.done)
                }
            }
        }

        do {
            try p.run()
            process = p
            stdin.fileHandleForWriting.write(Data(text.utf8))
            stdin.fileHandleForWriting.closeFile()
        } catch {
            onState(.failed(error.localizedDescription))
        }
    }

    private func enqueue(_ url: URL, text: String) {
        guard !stopped else { return }
        queue.append((url, text))
        if player == nil && autoplay { playNext() }
    }

    private func playNext() {
        guard !stopped else { return }
        wordTimer?.invalidate()
        wordTimer = nil
        guard !queue.isEmpty else {
            player = nil
            if rendererDone { onState?(.done) }
            return
        }
        let (url, text) = queue.removeFirst()
        defer { try? FileManager.default.removeItem(at: url) }
        guard let next = try? AVAudioPlayer(contentsOf: url) else {
            playNext()
            return
        }
        player = next
        next.delegate = self
        next.play()
        onState?(.speaking)
        startWordTimer(chunk: text, duration: next.duration)
    }

    // Drive the read-along highlight across this chunk's words over its duration.
    private func startWordTimer(chunk: String, duration: TimeInterval) {
        guard !chunk.isEmpty, duration > 0 else { return }
        let segLen = segment.length
        let from = min(searchOffset, segLen)
        var found = segment.range(of: chunk, options: [], range: NSRange(location: from, length: segLen - from))
        if found.location == NSNotFound {
            found = NSRange(location: from, length: min((chunk as NSString).length, segLen - from))
        }
        chunkOffset = found.location
        searchOffset = found.location + found.length
        chunkWords = wordRanges(in: chunk)
        lastWordIndex = -1
        guard !chunkWords.isEmpty else { return }
        let count = chunkWords.count
        wordTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] t in
            guard let self, let p = self.player, !self.stopped else { t.invalidate(); return }
            let frac = max(0, min(0.999, p.currentTime / duration))
            let wi = min(count - 1, Int(frac * Double(count)))
            guard wi != self.lastWordIndex else { return }
            self.lastWordIndex = wi
            let wr = self.chunkWords[wi]
            self.onWord?(NSRange(location: self.chunkOffset + wr.location, length: wr.length))
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.playNext() }
    }

    func pause() {
        player?.pause()
        onState?(.paused)
    }

    func resume() {
        if player != nil {
            player?.play()
            onState?(.speaking)
        } else {
            playNext()
        }
    }

    func stop() {
        stopped = true
        wordTimer?.invalidate()
        wordTimer = nil
        stdoutHandle?.readabilityHandler = nil   // defensive: cancel the read source on teardown too
        stdoutHandle = nil
        process?.terminate()
        player?.stop()
        player = nil
        for item in queue { try? FileManager.default.removeItem(at: item.url) } // delete undelivered TTS audio — never persist it
        queue.removeAll()
    }
}
