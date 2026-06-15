import AppKit

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
    private let listener = CorrectionListener()

    public override init() { super.init() }

    /// Whether dictation is on at all. When off, the hold-to-talk hotkey is never registered,
    /// so ⌃+Fn does nothing and the Microphone / Accessibility prompts are never reached — the
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
        if dictateEnabled { HotKey.shared.register() } // off → no monitor, no permission prompt
    }

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
        let toggle = NSMenuItem(title: "Dictate — hold ⌃ + Fn", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = dictateEnabled ? .on : .off
        items.append(toggle)
        guard dictateEnabled else { return items }

        let engine = NSMenuItem(title: "Engine: \(Transcribers.activeEngineName())", action: nil, keyEquivalent: "")
        engine.isEnabled = false
        items.append(engine)
        let learn = NSMenuItem(title: "Learn from edits", action: #selector(toggleLearn), keyEquivalent: "")
        learn.target = self
        learn.state = learnEnabled ? .on : .off
        items.append(learn)
        let dash = NSMenuItem(title: "Dictionary…", action: #selector(openDashboard), keyEquivalent: "d")
        dash.target = self
        items.append(dash)
        return items
    }

    // MARK: session

    /// Turn the whole capability on or off. Off → unregister the hotkey and tear down any
    /// in-flight session, so ⌃+Fn is inert and no mic/Accessibility prompt can be reached.
    @objc private func toggleEnabled() {
        dictateEnabled.toggle()
        if dictateEnabled {
            HotKey.shared.register()
        } else {
            HotKey.shared.unregister()
            state = .idle
            listener.stop(); LearnPill.shared.close()
            Overlay.shared.close()
        }
        onMenuRebuild?()
    }

    @objc private func toggleLearn() {
        learnEnabled.toggle()
        if !learnEnabled { listener.stop(); LearnPill.shared.close() }
        onMenuRebuild?() // refresh the checkmark in the shared menu
    }

    @objc private func openDashboard() {
        Lexicon.shared.load()
        Dashboard.shared.open(learnEnabled: { [weak self] in self?.learnEnabled ?? true },
                              toggleLearn: { [weak self] in self?.toggleLearn() }) // flips + keeps the menu in sync
    }

    private func hotKeyPressed() {
        guard state == .idle else { return } // debounce key-repeat / re-press
        listener.stop(); LearnPill.shared.close() // a new dictation supersedes any pending learn prompt
        state = .listening
        Overlay.shared.showListening()
        recorder.start(onError: { [weak self] message in
            self?.state = .idle
            Overlay.shared.flash(message: message)
        })
    }

    private func hotKeyReleased() {
        guard state == .listening else { return }
        state = .finishing
        guard let clip = recorder.stop() else { // nothing captured
            state = .idle
            Overlay.shared.close()
            return
        }
        // Too short, or silent: drop it silently rather than paste a phantom.
        if clip.duration < minClipSeconds {
            try? FileManager.default.removeItem(at: clip.url)
            state = .idle
            Overlay.shared.close()
            return
        }
        if clip.peak < silenceFloor {
            try? FileManager.default.removeItem(at: clip.url)
            state = .idle
            Overlay.shared.flash(message: "nothing heard")
            return
        }
        transcribeAndDeliver(clip)
    }

    /// One pass over the whole recorded clip, off the main thread, then clean +
    /// paste. The temp WAV is deleted as soon as we have the text — no audio is
    /// ever persisted.
    private func transcribeAndDeliver(_ clip: Recorder.Result) {
        Overlay.shared.showThinking()
        let wav = clip.url
        Transcribers.run(wav, clipDuration: clip.duration) { [weak self] text in
            try? FileManager.default.removeItem(at: wav)
            guard let self else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                self.state = .idle
                Overlay.shared.flash(message: "nothing heard")
                return
            }
            let cleaner = Cleaners.best()
            DispatchQueue.global(qos: .utility).async { // bun cleaner may block ~2s
                let cleaned = Lexicon.shared.apply(cleaner.clean(trimmed)) // cleanup, then your dictionary
                DispatchQueue.main.async { self.deliver(cleaned) }
            }
        }
    }

    private func deliver(_ cleaned: String) {
        state = .idle
        guard !cleaned.isEmpty else {
            Overlay.shared.flash(message: "nothing heard")
            return
        }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.state == .idle else { return }
            self.listener.start(pasted: pasted) { from, to in
                LearnPill.shared.show(from: from, to: to) {
                    Lexicon.shared.learn(from: from, to: to)
                    // Confirm in the same spot, with a Remove to undo on the spot.
                    LearnPill.shared.showAdded(word: to) { Lexicon.shared.forget(from) }
                }
            }
        }
    }
}
