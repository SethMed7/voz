import AVFoundation

/// Records raw mic audio for the whole hotkey hold into a temp WAV — no
/// recognizer, no endpointer, no silence cutoff. The finger is the only
/// endpoint: while the key is held we just keep writing, through any number of
/// thinking pauses. Transcription happens once, after release (see Transcriber).
///
/// Replaces the old streaming SFSpeechRecognizer, whose silence-finalize was the
/// "stop talking then start again and it forgets things" bug.
final class Recorder {
    struct Result {
        let url: URL            // temp 32-bit float WAV (whisper-cli reads it directly)
        let duration: TimeInterval
        let peak: Float         // loudest sample magnitude — the silence/short-tap gate
        let capped: Bool        // hit the runaway safety ceiling (stuck key)
    }

    /// Runaway protection only — NOT an endpointer. A missed key-up (a known
    /// Carbon hot-key failure mode) shouldn't grow a file forever. We stop
    /// writing past this; the user still gets the first MAX_SECONDS.
    private static let maxSeconds: Double = 5 * 60

    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var url: URL?
    private var active = false
    private var frames: AVAudioFramePosition = 0
    private var sampleRate: Double = 0
    private var peak: Float = 0
    private var capped = false

    /// Start recording to a fresh temp WAV. Mic permission is requested here
    /// (whisper needs no Speech entitlement). onError fires if we can't record.
    func start(onError: @escaping (String) -> Void) {
        active = true
        frames = 0
        peak = 0
        capped = false
        requestMic { [weak self] granted in
            guard let self, self.active else { return } // released during the dialog
            guard granted else { self.active = false; onError("grant Microphone in System Settings"); return }
            self.begin(onError: onError)
        }
    }

    private func begin(onError: @escaping (String) -> Void) {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { active = false; onError("no audio input device"); return }
        sampleRate = format.sampleRate
        let maxFrames = AVAudioFramePosition(Self.maxSeconds * sampleRate)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("voz-\(ProcessInfo.processInfo.globallyUniqueString).wav")
        do {
            file = try AVAudioFile(forWriting: tmp, settings: format.settings)
        } catch {
            active = false
            onError("could not open audio file: \(error.localizedDescription)")
            return
        }
        url = tmp

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, self.active else { return }
            if self.frames >= maxFrames { self.capped = true; return } // runaway guard
            self.trackPeak(buffer)
            try? self.file?.write(from: buffer)
            self.frames += AVAudioFramePosition(buffer.frameLength)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            active = false
            file = nil
            onError("audio input failed: \(error.localizedDescription)")
            return
        }
        self.engine = engine
    }

    /// Stop and hand back the recorded clip (or nil if nothing was captured).
    /// removeTap first so no further writes race the close.
    func stop() -> Result? {
        guard active else { return nil }
        active = false
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        file = nil // ARC closes/flushes the WAV
        guard let url, sampleRate > 0, frames > 0 else { return nil }
        let duration = Double(frames) / sampleRate
        return Result(url: url, duration: duration, peak: peak, capped: capped)
    }

    /// Loudest sample magnitude in this buffer — drives the silence gate so a
    /// key-tap with no speech never reaches whisper (which hallucinates on
    /// silence). Falls back to "assume signal" for non-float formats.
    private func trackPeak(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData else { peak = max(peak, 1); return }
        let n = Int(buffer.frameLength)
        let samples = ch[0]
        var localMax: Float = 0
        for i in 0..<n {
            let a = abs(samples[i])
            if a > localMax { localMax = a }
        }
        if localMax > peak { peak = localMax }
    }

    private func requestMic(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }
}
