import AppKit
import Carbon.HIToolbox
import Shared

public final class SpeakController: NSObject {
    static private(set) var shared: SpeakController!

    /// The app coordinator owns the shared status item; we report icon/menu changes up.
    /// Icon updates carry a priority so the coordinator can arbitrate between the two
    /// capabilities (higher wins): 0 = idle, 1 = an active read-aloud session.
    public var onIcon: ((Int, String) -> Void)?
    public var onMenuRebuild: (() -> Void)?

    /// Fired when a selection is read aloud (text, source app, voice). The app coordinator routes it
    /// to Insights — read-aloud lives in a different module than the stats store.
    public var onRead: ((_ text: String, _ appBundleId: String?, _ appName: String?, _ voice: String) -> Void)?

    private var started = false

    /// Whether read-aloud is on at all. When off, ⌃V is unregistered and the Services entry
    /// is inert, so nothing can reach the Accessibility prompt until you turn it on. On by default.
    private var speakEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "speakEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "speakEnabled") }
    }

    private let services = ServiceProvider()
    private var handlerInstalled = false
    private var hotKeyRef: EventHotKeyRef?
    private var watchMenuItem: NSMenuItem!

    public override init() { super.init() }

    // MARK: capture-session state
    //
    // captureMode  — we're watching the mouse/keyboard for new highlights.
    // sessionActive — a capture session exists (the queue may still be draining
    //                 even after watching is turned off via ✕ / Esc).
    private var captureMode = false
    private var sessionActive = false
    private var grabbing = false
    private var grabSession = 0   // bumped when a session starts/ends; a grab tagged with a stale id is discarded
    private var lastCaptured: String?
    private var mouseDownPoint = NSPoint.zero
    private var mouseDownMonitor: Any?
    private var mouseUpMonitor: Any?

    /// Wire up the read-aloud capability: the Services entry, the read-along queue,
    /// and the ⌃V hotkey. The status item + menu are owned by the app coordinator.
    public func start() {
        guard !started else { return } // idempotent: never double-install the handler / hotkey
        started = true
        SpeakController.shared = self
        setStatusIcon(watching: false)

        NSApp.servicesProvider = services
        NSUpdateDynamicServices()

        Speaker.shared.onQueueDrained = { [weak self] in self?.handleQueueDrained() }

        installEventHandler()                       // the dispatch handler is harmless when no hotkey is live
        if speakEnabled { registerHotKey(); prewarmTTS() } // off → ⌃V never fires; on → warm Kokoro early
    }

    /// Warm the Kokoro TTS server in the background so the model is resident before the first read.
    /// No-ops if the warm server isn't installed (voz then uses the per-spawn cold path).
    private func prewarmTTS() {
        DispatchQueue.global(qos: .utility).async { WarmTTS.shared.prewarm() }
    }

    /// The read-aloud section of the shared menu. Rebuilt by the coordinator on demand.
    /// The header is the on/off switch for the whole capability; when off it stands alone.
    public func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let toggle = NSMenuItem(title: "Read aloud — select + ⌃V", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = speakEnabled ? .on : .off
        items.append(toggle)
        guard speakEnabled else { return items }

        watchMenuItem = NSMenuItem(title: "Watch selections  ⌃V", action: #selector(toggleCapture), keyEquivalent: "")
        watchMenuItem.target = self
        watchMenuItem.state = sessionActive ? .on : .off
        items.append(watchMenuItem)
        let read = NSMenuItem(title: "Read Selection", action: #selector(readSelection), keyEquivalent: "")
        read.target = self
        items.append(read)
        let stop = NSMenuItem(title: "Stop Reading", action: #selector(stopSpeaking), keyEquivalent: "")
        stop.target = self
        items.append(stop)
        let voiceItem = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        let voiceMenu = NSMenu()
        for voice in Voices.all {
            let item = NSMenuItem(title: voice.label, action: #selector(selectVoice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = voice.id
            item.state = voice.id == Speaker.shared.voiceId ? .on : .off
            voiceMenu.addItem(item)
        }
        voiceItem.submenu = voiceMenu
        items.append(voiceItem)
        return items
    }

    @objc private func selectVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Speaker.shared.setVoice(id)
        for item in sender.menu?.items ?? [] {
            item.state = (item.representedObject as? String) == id ? .on : .off
        }
    }

    // MARK: enable / disable the whole capability

    /// Turn read-aloud on or off. Off → stop any session and unregister ⌃V, so the capability
    /// is fully inert and the Services entry no-ops (see `readOneShot`).
    @objc private func toggleEnabled() {
        speakEnabled.toggle()
        if speakEnabled {
            registerHotKey()
            prewarmTTS()
        } else {
            endSessionHard()        // stops watching + speaking, closes the bar, drops the esc hotkey
            unregisterHotKey()
        }
        onMenuRebuild?()
    }

    // MARK: capture mode (the ⌃V toggle)

    /// Menu "Watch selections": a plain toggle (the menu item carries the checkmark).
    @objc func toggleCapture() {
        if sessionActive {
            endSessionHard()
        } else {
            startCapture()
        }
    }

    /// ⌃V — always (re)arm watching. Never a dead press: it clears any lingering or wedged session
    /// (e.g. a read still finishing, or one that didn't drain) and starts a fresh watch. Stopping is
    /// Esc (or the menu toggle), not ⌃V — so pressing ⌃V a second time always does the obvious thing.
    func startWatching() {
        removeMonitors()   // drop any existing watch monitors first (idempotent) so we never double-install
        startCapture()
    }

    private func startCapture() {
        prewarmTTS()       // get Kokoro resident before the first highlight (no-op if not installed)
        grabSession += 1   // invalidate any in-flight grab from a prior session so it can't leak in
        grabbing = false   // …and never let a stale flag block this fresh session's first read
        sessionActive = true
        captureMode = true
        lastCaptured = nil
        cancelIdleClose()
        Speaker.shared.stop()
        setStatusIcon(watching: true)
        watchMenuItem?.state = .on
        Overlay.shared.present(watching: true)
        Overlay.shared.center() // always start bottom-center
        Overlay.shared.clearTranscript(placeholder: "Highlight text anywhere — voz reads each selection in order and follows along word by word.")
        Overlay.shared.setStatus("watching — highlight to read")
        installMonitors()
        registerEscapeHotKey() // Esc stops the whole session, for its full life (not just while watching)
        // Honor the old muscle memory: if something is already selected, read it.
        captureCurrentSelection()
    }

    /// ✕ / Esc: stop watching for new highlights, but let the queue finish.
    func exitWatching() {
        guard captureMode else { return }
        captureMode = false
        grabbing = false
        removeMonitors()
        setStatusIcon(watching: false)
        watchMenuItem?.state = .off
        Overlay.shared.setWatching(false)
        if Speaker.shared.isActive || Speaker.shared.pending > 0 {
            Overlay.shared.setStatus("reading — Esc again to stop")
        } else {
            // Stopped watching with nothing queued — stay open so a second Esc closes it (the two-stage
            // model), but don't linger forever if you walk away.
            Overlay.shared.setStatus("stopped — Esc again to close")
            scheduleIdleClose(8)
        }
    }

    /// Esc / ■: stop reading and close the bar.
    func endSessionHard() {
        cancelIdleClose()
        captureMode = false
        sessionActive = false
        grabbing = false
        grabSession += 1   // any grab still in flight from this session is now stale
        removeMonitors()
        unregisterEscapeHotKey()
        setStatusIcon(watching: false)
        watchMenuItem?.state = .off
        Speaker.shared.stop()
        Overlay.shared.close()
    }

    /// The queue finished on its own and we're no longer watching.
    private func endSessionSoft() {
        sessionActive = false
        grabbing = false
        unregisterEscapeHotKey()
        setStatusIcon(watching: false)
        watchMenuItem?.state = .off
        Overlay.shared.finish()
    }

    // Auto-close when done: even while watching, close shortly after the queue drains unless a new
    // highlight arrives (which cancels it). Keeps the multi-highlight flow but doesn't linger.
    private var idleCloseWork: DispatchWorkItem?
    private func scheduleIdleClose(_ seconds: TimeInterval) {
        idleCloseWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.endSessionHard() }
        idleCloseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }
    private func cancelIdleClose() { idleCloseWork?.cancel(); idleCloseWork = nil }

    private func handleQueueDrained() {
        if captureMode {
            // Done reading what's queued — close soon unless you highlight again.
            Overlay.shared.setStatus("done")
            scheduleIdleClose(6)
        } else if sessionActive {
            endSessionSoft()
        } else {
            // A one-shot read (Services / "Read Selection") finished.
            unregisterEscapeHotKey()
            Overlay.shared.finish()
        }
    }

    // MARK: one-shot reads (Services / menu) — unchanged behavior

    func readOneShot(_ text: String) {
        guard speakEnabled else { return } // disabled capability is inert, incl. the Services entry
        cancelIdleClose()  // a stale idle-close timer from a capture session must not abort this read
        captureMode = false
        sessionActive = false
        grabbing = false
        removeMonitors()
        setStatusIcon(watching: false)
        watchMenuItem?.state = .off
        Overlay.shared.present(watching: false)
        Overlay.shared.center() // always start bottom-center
        registerEscapeHotKey()  // Esc stops a one-shot read too
        let app = NSWorkspace.shared.frontmostApplication
        onRead?(text, app?.bundleIdentifier, app?.localizedName, Speaker.shared.voiceId)
        Speaker.shared.speakNow(text)
    }

    @objc func readSelection() {
        SelectionGrabber.grab { [weak self] text in
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                Overlay.shared.flash(message: "No text selected")
                return
            }
            self?.readOneShot(text)
        }
    }

    @objc func stopSpeaking() {
        endSessionHard()
    }

    /// Quit-time teardown: stop any read and kill the Kokoro subprocess + delete its temp audio. The
    /// overlay/hotkey state is moot at quit, so we just stop the engine pipeline (mirrors dictate.shutdown).
    public func shutdown() {
        cancelIdleClose()
        unregisterEscapeHotKey()
        Speaker.shared.stop()
        WarmTTS.shared.shutdown() // kill the resident TTS server we may have spawned
    }

    // MARK: watching the user's highlights

    private func installMonitors() {
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.mouseDownPoint = NSEvent.mouseLocation
        }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self else { return }
            let up = NSEvent.mouseLocation
            let dragged = hypot(up.x - self.mouseDownPoint.x, up.y - self.mouseDownPoint.y) > 4
            // A drag is a sweep-select; clickCount ≥ 2 is a word/line double- or triple-click;
            // a Shift-click extends the selection to where you clicked. Plain single clicks aren't
            // selections, so we skip those and avoid spamming synthetic ⌘C.
            if dragged || event.clickCount >= 2 || event.modifierFlags.contains(.shift) {
                self.captureCurrentSelection()
            }
        }
    }

    private func removeMonitors() {
        for monitor in [mouseDownMonitor, mouseUpMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        mouseDownMonitor = nil
        mouseUpMonitor = nil
    }

    private func captureCurrentSelection() {
        guard captureMode, !grabbing else { return }
        grabbing = true
        let gen = grabSession
        SelectionGrabber.grab { [weak self] text in
            guard let self else { return }
            // A grab started by a session that has since closed or re-armed is stale: drop it WITHOUT
            // touching `grabbing` (a newer session may own it now), so old text can't bleed into a new one.
            guard self.grabSession == gen else { return }
            self.grabbing = false
            guard self.captureMode else { return }
            let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != self.lastCaptured else { return }
            // Shift-click / drag to EXTEND a selection re-grabs the whole thing, so read only the new
            // tail instead of duplicating what was just read. Guard it on a word boundary: an unrelated
            // selection that merely shares a prefix ("The cat" → "The catalog") must be read in full,
            // not as a mid-word fragment ("alog is huge").
            var toRead = trimmed
            if let last = self.lastCaptured, !last.isEmpty, trimmed.hasPrefix(last) {
                let boundary = trimmed.index(trimmed.startIndex, offsetBy: last.count)
                let atWordBreak = boundary == trimmed.endIndex
                    || trimmed[boundary].isWhitespace
                    || (last.last.map { !$0.isLetter && !$0.isNumber } ?? false)
                if atWordBreak {
                    let tail = String(trimmed[boundary...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if tail.isEmpty { self.lastCaptured = trimmed; return }
                    toRead = tail
                }
            }
            self.lastCaptured = trimmed
            self.cancelIdleClose() // a new highlight keeps the session alive
            Overlay.shared.present(watching: true)
            Speaker.shared.enqueue(toRead)
            let app = NSWorkspace.shared.frontmostApplication // where you read it from
            self.onRead?(toRead, app?.bundleIdentifier, app?.localizedName, Speaker.shared.voiceId)
        }
    }

    private func setStatusIcon(watching: Bool) {
        onIcon?(watching ? 1 : 0, watching ? "waveform.circle.fill" : "play.bubble")
    }

    // MARK: hotkey (⌃V) via Carbon — no dependencies, works on every macOS.

    /// Install the single Carbon event handler that dispatches both hotkeys by id. Done once and
    /// kept for the app's life — it's inert until a hotkey is actually registered, so it's safe to
    /// install even while read-aloud is off.
    private func installEventHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        // This is ONE of two hotkey handlers on the app's event target (the other is EscapeKey's).
        // Every handler sees every hotkey-pressed event, so we MUST return eventNotHandledErr for
        // hotkeys we don't own — returning noErr unconditionally would swallow the event and starve
        // the other handler (the exact bug that made ⌃V die after the first read-aloud session armed
        // Escape). Only ⌃V (id 1) is ours.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            if hk.id == 1 {
                DispatchQueue.main.async { SpeakController.shared.startWatching() }
                return noErr
            }
            return OSStatus(eventNotHandledErr) // let Escape (and anything else) reach its handler
        }, 1, &eventType, nil, nil)
    }

    /// Register ⌃V (the watch toggle). Idempotent; toggled with read-aloud on/off.
    private func registerHotKey() {
        guard hotKeyRef == nil else { return }
        let hotKeyID = EventHotKeyID(signature: OSType(0x766F_7A20), id: 1) // "voz "
        RegisterEventHotKey(UInt32(kVK_ANSI_V),
                            UInt32(controlKey),
                            hotKeyID,
                            GetApplicationEventTarget(),
                            0,
                            &hotKeyRef)
    }

    /// Drop ⌃V so the key is normal again (used when read-aloud is toggled off).
    private func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    // Escape is the read-aloud stop key — two-stage (see handleEscape). Claimed from the shared
    // EscapeKey owner so it never collides with dictation's Esc, for the session's full life, so
    // Escape is normal whenever voz isn't reading.
    private func registerEscapeHotKey() { EscapeKey.shared.claim(self) { [weak self] in self?.handleEscape() } }
    private func unregisterEscapeHotKey() { EscapeKey.shared.release(self) }

    /// Esc is two-stage: the FIRST press stops *watching* for new highlights but keeps reading the
    /// queue and stays open; a SECOND press stops reading and closes. (Mirrors the ✕ then ■ buttons.)
    private func handleEscape() {
        if captureMode { exitWatching() } else { endSessionHard() }
    }
}

/// Right-click → Services → "Read Aloud with voz". Receives the selection
/// as plain text via the pasteboard — images in a selection simply don't
/// arrive, so they're skipped by construction.
final class ServiceProvider: NSObject {
    @objc func readAloud(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = "voz: no text in selection" as NSString
            return
        }
        DispatchQueue.main.async {
            SpeakController.shared.readOneShot(text)
        }
    }
}
