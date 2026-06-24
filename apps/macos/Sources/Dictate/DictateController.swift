import AppKit
import Carbon.HIToolbox
import Shared

public final class DictateController: NSObject {
    static private(set) var shared: DictateController!

    /// The app coordinator owns the shared status item; we report icon/menu changes up.
    /// Icon updates carry a priority so the coordinator can arbitrate between the two
    /// capabilities (higher wins): 0 = idle, 3 = recording (the mic must never be ambiguous).
    public var onIcon: ((Int, String) -> Void)?
    public var onMenuRebuild: (() -> Void)?

    private var started = false

    /// idle -> listening (key held, recording) -> finishing (transcribe + paste) -> idle
    private enum State { case idle, listening, finishing }
    private var state: State = .idle { didSet { updateStatusIcon() } }

    private let recorder = Recorder()
    private let learner = KeystrokeLearner() // learns corrections from keystrokes — works in terminals too
    private var handsFree = false // true while a double-tap-⌃ (no-hold) session is recording
    private var recordingWatchdog: DispatchWorkItem? // force-finishes a stuck session if a key-up is dropped
    /// Bumped whenever a session ends or is cancelled, so a late transcribe/polish completion from a
    /// superseded run is ignored — both Esc-to-cancel and the processing watchdog rely on this.
    private var workGen = 0
    private var processingWatchdog: DispatchWorkItem? // force-resets if transcribe/polish wedges on a stuck engine

    // In-memory safety net: the last few cleaned dictations, so a paste that lands in the wrong app or
    // field isn't lost forever (you'd otherwise have to re-say it). Never written to disk — consistent
    // with "no recording is ever saved" — and cleared when voz quits. Retrieve from the menu via
    // "Copy Last Dictation" / "Recent Dictations".
    private var recentTranscripts: [String] = []
    private let maxRecent = 10

    /// The app being dictated INTO, captured at recording start (before focus can change) for per-app stats.
    private var dictationApp: (bundleId: String?, name: String?)?
    /// Whether a secure (password) field was focused at recording start — so Insights can keep metrics only.
    private var dictationSecure = false
    private static let passwordManagerBundleIDs: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword",
        "com.bitwarden.desktop", "org.keepassxc.keepassxc", "com.lastpass.LastPass", "com.apple.keychainaccess",
    ]

    /// Whether double-tap ⌃ starts a hands-free dictation. On by default; toggle in the menu.
    private var handsFreeEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "handsFreeEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "handsFreeEnabled") }
    }

    public override init() { super.init() }

    /// Whether dictation is on at all. When off, the hold-to-talk hotkey is never registered,
    /// so Fn does nothing and the Microphone / Accessibility prompts are never reached — the
    /// permission for a capability is only ever asked once you've turned it on. On by default.
    private var dictateEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "dictateEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "dictateEnabled") }
    }

    /// Watch the field after a paste and offer to learn spelling fixes. On by default; toggle in the menu.
    private var learnEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "learnFromEdits") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "learnFromEdits") }
    }

    // Guards so an accidental tap or a silent hold never reaches whisper (which
    // hallucinates on silence) or pastes garbage. Starting points — tune to taste.
    private let minClipSeconds = 0.4
    private let silenceFloor: Float = 0.01 // peak sample magnitude (-1...1)

    /// Wire up the dictation capability: the hold-to-talk hotkey and recorder.
    /// The status item + menu are owned by the app coordinator.
    public func start() {
        guard !started else { return } // idempotent: never double-register the hotkey
        started = true
        DictateController.shared = self
        updateStatusIcon()

        HotKey.shared.onPress = { [weak self] in self?.hotKeyPressed() }
        HotKey.shared.onRelease = { [weak self] in self?.hotKeyReleased() }
        HotKey.shared.onDoubleTap = { [weak self] in self?.handsFreeToggle() }
        if dictateEnabled { HotKey.shared.register() } // off → no monitor, no permission prompt
    }

    /// Tear down background helpers (the warm ASR + LLM servers) when the app quits.
    public func shutdown() { WarmASR.shared.shutdown(); WarmLLM.shared.shutdown() }

    /// Menu-bar glyph reflects state so the mic is never ambiguously "on": idle = mic,
    /// recording/processing = mic.fill. (A common complaint in this app class is not knowing
    /// whether it's listening.)
    private func updateStatusIcon() {
        // Recording outranks any read-aloud state so the hot mic is never masked.
        onIcon?(state == .idle ? 0 : 3, state == .idle ? "mic" : "mic.fill")
    }

    /// The dictation section of the shared menu. Rebuilt by the coordinator on demand.
    /// The header is the on/off switch for the whole capability; when off it stands alone
    /// (no engine row, no dictionary) so the menu reads as "this mode is parked".
    public func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let toggle = NSMenuItem(title: "Dictate — hold Fn to record", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = dictateEnabled ? .on : .off
        items.append(toggle)
        guard dictateEnabled else { return items }

        let engine = NSMenuItem(title: "Engine: \(Transcribers.activeEngineName())", action: nil, keyEquivalent: "")
        engine.isEnabled = false
        items.append(engine)

        let insights = NSMenuItem(title: "Insights…", action: #selector(openInsights), keyEquivalent: "i")
        insights.target = self
        items.append(insights)

        // Recovery: if a dictation pasted somewhere wrong, grab it here instead of re-saying it.
        if let last = recentTranscripts.first {
            let copyLast = NSMenuItem(title: "Copy Last Dictation", action: #selector(copyLastTranscript), keyEquivalent: "")
            copyLast.target = self
            copyLast.toolTip = oneLine(last)
            items.append(copyLast)
            if recentTranscripts.count > 1 {
                let recent = NSMenuItem(title: "Recent Dictations", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for (i, t) in recentTranscripts.enumerated() {
                    let it = NSMenuItem(title: preview(t), action: #selector(copyRecent(_:)), keyEquivalent: "")
                    it.target = self
                    it.tag = i
                    it.toolTip = oneLine(t)
                    sub.addItem(it)
                }
                recent.submenu = sub
                items.append(recent)
            }
        }

        if MLXCleaner.isAvailable() || LLMCleaner.isAvailable() {
            let ai = NSMenuItem(title: "Polish with AI (on-device)", action: #selector(toggleLLM), keyEquivalent: "")
            ai.target = self
            ai.state = Cleaners.llmEnabled ? .on : .off
            items.append(ai)
        }
        let hands = NSMenuItem(title: "Hands-free — double-tap Fn", action: #selector(toggleHandsFree), keyEquivalent: "")
        hands.target = self
        hands.state = handsFreeEnabled ? .on : .off
        items.append(hands)
        let learn = NSMenuItem(title: "Learn from edits", action: #selector(toggleLearn), keyEquivalent: "")
        learn.target = self
        learn.state = learnEnabled ? .on : .off
        items.append(learn)
        let dash = NSMenuItem(title: "Dictionary…", action: #selector(openDictionary), keyEquivalent: "d")
        dash.target = self
        items.append(dash)
        return items
    }

    // MARK: session

    /// Turn the whole capability on or off. Off → unregister the hotkey and tear down any
    /// in-flight session, so the Fn hotkey is inert and no mic/Accessibility prompt can be reached.
    @objc private func toggleEnabled() {
        dictateEnabled.toggle()
        if dictateEnabled {
            HotKey.shared.register()
        } else {
            HotKey.shared.unregister()
            workGen &+= 1 // invalidate any in-flight transcribe/polish
            recordingWatchdog?.cancel(); recordingWatchdog = nil
            processingWatchdog?.cancel(); processingWatchdog = nil
            unregisterEsc() // and don't leave Esc consumed if we were recording
            if let clip = recorder.stop() { try? FileManager.default.removeItem(at: clip.url) }
            state = .idle
            learner.stop(); LearnPill.shared.close()
            Overlay.shared.close()
        }
        onMenuRebuild?()
    }

    @objc private func toggleLLM() {
        Cleaners.llmEnabled.toggle()
        onMenuRebuild?() // refresh the checkmark in the shared menu
    }

    @objc private func toggleHandsFree() {
        handsFreeEnabled.toggle()
        onMenuRebuild?() // refresh the checkmark in the shared menu
    }

    @objc private func toggleLearn() {
        learnEnabled.toggle()
        if !learnEnabled { learner.stop(); LearnPill.shared.close() }
        onMenuRebuild?() // refresh the checkmark in the shared menu
    }

    @objc private func openInsights() { InsightsWindow.shared.open(section: .home) }
    @objc private func openDictionary() { InsightsWindow.shared.open(section: .dictionary) }

    // MARK: recent dictations — a safety net for a mis-targeted paste

    private func remember(_ text: String) {
        recentTranscripts.removeAll { $0 == text }     // most-recent-first, de-duplicated
        recentTranscripts.insert(text, at: 0)
        if recentTranscripts.count > maxRecent { recentTranscripts.removeLast() }
        onMenuRebuild?() // keep "Copy Last Dictation" / the submenu current
    }

    @objc private func copyLastTranscript() {
        guard let t = recentTranscripts.first else { return }
        copyToClipboard(t)
    }
    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard recentTranscripts.indices.contains(sender.tag) else { return }
        copyToClipboard(recentTranscripts[sender.tag])
    }
    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        Overlay.shared.flash(message: "copied — ⌘V to paste")
    }
    private func preview(_ s: String) -> String {
        let one = oneLine(s)
        return one.count > 48 ? String(one.prefix(47)) + "…" : one
    }
    private func oneLine(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
    }

    // Hold Fn: press starts, release stops.
    private func hotKeyPressed() {
        guard state == .idle else { return } // debounce key-repeat / re-press
        handsFree = false
        beginRecording()
    }
    private func hotKeyReleased() {
        guard state == .listening, !handsFree else { return } // a release only ends a *hold* session
        finishRecording()
    }

    /// Double-tap Fn — hands-free mode: the first toggle starts recording (no need to hold), the next
    /// stops and delivers. Lets you dictate without keeping the key down.
    private func handsFreeToggle() {
        guard dictateEnabled, handsFreeEnabled else { return }
        if state == .idle { handsFree = true; beginRecording() }
        else if state == .listening, handsFree { finishRecording() }
    }

    private func beginRecording() {
        // Capture the app being dictated into NOW, before anything can change focus — the per-app signal.
        let app = NSWorkspace.shared.frontmostApplication
        // If voz's own window (Insights/Dictionary) is frontmost, don't attribute the dictation to voz.
        let isSelf = app?.bundleIdentifier == Bundle.main.bundleIdentifier
        dictationApp = isSelf ? (nil, nil) : (app?.bundleIdentifier, app?.localizedName)
        dictationSecure = IsSecureEventInputEnabled()
            || ((app?.bundleIdentifier).map(Self.passwordManagerBundleIDs.contains) ?? false)
        learner.stop(); LearnPill.shared.close() // a new dictation supersedes any pending learn prompt
        workGen &+= 1 // a fresh session; any straggler completion from before is now stale
        registerEsc() // Esc cancels — while recording, and through processing
        state = .listening
        Overlay.shared.showListening()
        // Warm the engines now so their load overlaps with you speaking, not the paste path:
        // the warm Parakeet ASR server and the LLM polish model.
        DispatchQueue.global(qos: .utility).async {
            WarmASR.shared.ensureRunning()
            if Cleaners.llmEnabled, MLXCleaner.isAvailable() { WarmLLM.shared.ensureRunning() }
        }
        recorder.onLevel = { Overlay.shared.updateLevel($0) }
        recorder.start(onError: { [weak self] message in
            self?.recordingWatchdog?.cancel()
            self?.unregisterEsc() // don't leave Esc globally consumed if the mic couldn't start
            self?.state = .idle
            Overlay.shared.flash(message: message)
        })
        // Safety net: if a Fn key-up is ever dropped, force-finish so Esc + the mic can't wedge forever.
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.state == .listening else { return }
            self.finishRecording()
        }
        recordingWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 305, execute: watchdog)
    }

    private func finishRecording() {
        recordingWatchdog?.cancel(); recordingWatchdog = nil
        state = .finishing // Esc stays claimed → it now cancels the transcribe/polish (see escapePressed)
        guard let clip = recorder.stop() else { // nothing captured
            unregisterEsc(); state = .idle
            Overlay.shared.close()
            return
        }
        // Too short, or silent: drop it silently rather than paste a phantom.
        if clip.duration < minClipSeconds {
            try? FileManager.default.removeItem(at: clip.url)
            unregisterEsc(); state = .idle
            Overlay.shared.close()
            return
        }
        if clip.peak < silenceFloor {
            try? FileManager.default.removeItem(at: clip.url)
            unregisterEsc(); state = .idle
            Overlay.shared.flash(message: "nothing heard")
            return
        }
        transcribeAndDeliver(clip)
    }

    /// Esc while recording — discard the clip, paste nothing. Works for both hold and hands-free.
    fileprivate func cancelRecording() {
        guard state == .listening else { return }
        workGen &+= 1
        recordingWatchdog?.cancel(); recordingWatchdog = nil
        unregisterEsc()
        handsFree = false
        recorder.onLevel = nil
        if let clip = recorder.stop() { try? FileManager.default.removeItem(at: clip.url) }
        state = .idle
        Overlay.shared.flash(message: "cancelled")
    }

    /// Esc while processing — abandon a transcribe/polish that's taking too long (or has wedged). The
    /// in-flight subprocess finishes harmlessly in the background; bumping workGen makes its result a
    /// no-op (no paste), so the UI is free immediately and a new dictation can start.
    fileprivate func cancelProcessing() {
        guard state == .finishing else { return }
        workGen &+= 1
        processingWatchdog?.cancel(); processingWatchdog = nil
        unregisterEsc()
        state = .idle
        Overlay.shared.flash(message: "cancelled")
    }

    // MARK: Esc-to-cancel — via the shared EscapeKey owner, so it never collides with read-aloud's Esc.
    // Claimed from recording start and held through processing; the handler routes by state so the same
    // key discards a recording mid-capture OR cancels a stuck transcribe/polish.

    private func registerEsc() { EscapeKey.shared.claim(self) { [weak self] in self?.escapePressed() } }
    private func unregisterEsc() { EscapeKey.shared.release(self) }
    private func escapePressed() {
        switch state {
        case .listening: cancelRecording()
        case .finishing: cancelProcessing()
        case .idle: break
        }
    }

    /// Safety net for the processing phase: if transcribe/polish wedges on a stuck engine, force back to
    /// idle (and free Esc) after a generous, clip-scaled bound, so the pill can never spin forever.
    private func startProcessingWatchdog(gen: Int, clipDuration: TimeInterval) {
        processingWatchdog?.cancel()
        let bound = max(30, clipDuration * 3 + 25)
        let wd = DispatchWorkItem { [weak self] in
            guard let self, self.state == .finishing, self.workGen == gen else { return }
            self.workGen &+= 1
            self.processingWatchdog = nil
            self.unregisterEsc()
            self.state = .idle
            Overlay.shared.flash(message: "took too long — press Fn to retry")
        }
        processingWatchdog = wd
        DispatchQueue.main.asyncAfter(deadline: .now() + bound, execute: wd)
    }

    /// Tear down the processing phase for a normal non-paste exit (e.g. "nothing heard"), if still current.
    private func endProcessing(gen: Int) {
        guard workGen == gen else { return }
        processingWatchdog?.cancel(); processingWatchdog = nil
        unregisterEsc()
        state = .idle
    }

    /// One pass over the whole recorded clip, off the main thread, then clean +
    /// paste. The temp WAV is deleted as soon as we have the text — no audio is
    /// ever persisted. Esc (or the watchdog) can cancel mid-flight: each completion
    /// re-checks `workGen`, so a superseded run never pastes.
    private func transcribeAndDeliver(_ clip: Recorder.Result) {
        Overlay.shared.showThinking()
        let gen = workGen
        startProcessingWatchdog(gen: gen, clipDuration: clip.duration)
        // Snapshot the metrics deliver() doesn't otherwise have — the clip's duration (→WPM), the
        // engine, and the app captured at recording start — so per-dictation stats can be recorded.
        let ctx = DictationContext(durationMs: Int(clip.duration * 1000),
                                   engine: Transcribers.activeEngineName(),
                                   appBundleId: dictationApp?.bundleId,
                                   appName: dictationApp?.name,
                                   secure: dictationSecure)
        let wav = clip.url
        Transcribers.run(wav, clipDuration: clip.duration) { [weak self] text in
            guard let self else { try? FileManager.default.removeItem(at: wav); return }
            guard self.workGen == gen else { try? FileManager.default.removeItem(at: wav); return } // cancelled
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                try? FileManager.default.removeItem(at: wav) // nothing heard — don't keep the audio
                self.endProcessing(gen: gen)
                Overlay.shared.flash(message: "nothing heard")
                return
            }
            DispatchQueue.global(qos: .utility).async { // LLM / bun cleaner may block
                let spell = SpellOut.process(trimmed) // resolve any spoken spelling first
                let cleaner = Cleaners.best(for: spell.text) // skips the LLM when already clean; off main
                let cleaned = Lexicon.shared.apply(cleaner.clean(spell.text)) // cleanup, then your dictionary
                DispatchQueue.main.async {
                    guard self.workGen == gen else { try? FileManager.default.removeItem(at: wav); return } // cancelled during polish
                    for rule in spell.learned { Lexicon.shared.learnExplicit(from: rule.from, to: rule.to) }
                    self.deliver(cleaned, ctx: ctx, audio: wav) // record copies the recording (when saving is on)
                    try? FileManager.default.removeItem(at: wav) // then drop the temp WAV
                    if let word = spell.learned.first?.to { // confirm what spelling was locked in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            LearnPill.shared.showAdded(word: word) { spell.learned.forEach { Lexicon.shared.forget($0.from) } }
                        }
                    }
                }
            }
        }
    }

    private func deliver(_ cleaned: String, ctx: DictationContext, audio: URL?) {
        processingWatchdog?.cancel(); processingWatchdog = nil
        unregisterEsc()
        state = .idle
        guard !cleaned.isEmpty else {
            Overlay.shared.flash(message: "nothing heard")
            return
        }
        remember(cleaned)                                                // in-memory safety net for a mis-targeted paste
        InsightStore.shared.record(cleaned, ctx: ctx, audioSource: audio) // local stats + history (+ saved recording)
        if Paster.paste(cleaned) {
            Overlay.shared.showTyped()
            startLearning(pasted: cleaned)
        } else {
            // Accessibility denied: text is on the clipboard. Echo it so the user
            // can confirm what was captured before pasting manually — the one
            // place the old live preview earned its keep.
            Overlay.shared.showCopied(cleaned)
        }
    }

    /// After a paste, watch the field for a few seconds; if Seth fixes a word's spelling,
    /// offer to remember it. Waits for the paste to land first, and bails if a new dictation
    /// started in the meantime.
    private func startLearning(pasted: String) {
        guard learnEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.state == .idle else { return }
            let watching = self.learner.start(pasted: pasted) { from, to in
                // Frequency-gated: each in-place fix is tallied; a word only becomes a
                // permanent rule once you've corrected it the same way enough times.
                switch Lexicon.shared.recordCorrection(from: from, to: to) {
                case .promoted(let word):
                    LearnPill.shared.showAdded(word: word) { Lexicon.shared.forgetTarget(word) }
                case .pending(let word, let count, let threshold):
                    LearnPill.shared.showProgress(word: word, count: count, of: threshold)
                case .ignored:
                    break
                }
            }
            // If voz can't read this app's text (most browsers/Electron apps), it can't learn edits
            // here — say so once so it isn't silently mysterious. Native fields (Notes, TextEdit…) work.
            if !watching, !UserDefaults.standard.bool(forKey: "warnedNoWatch") {
                UserDefaults.standard.set(true, forKey: "warnedNoWatch")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    LearnPill.shared.showNote("voz can’t watch this app to learn edits")
                }
            }
        }
    }
}
