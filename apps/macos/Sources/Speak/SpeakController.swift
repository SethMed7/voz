import AppKit
import Carbon.HIToolbox

public final class SpeakController: NSObject {
    static private(set) var shared: SpeakController!

    /// The app coordinator owns the shared status item; we report icon changes up.
    public var onIcon: ((String) -> Void)?

    private let services = ServiceProvider()
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
    private var lastCaptured: String?
    private var mouseDownPoint = NSPoint.zero
    private var mouseDownMonitor: Any?
    private var mouseUpMonitor: Any?
    private var escHotKeyRef: EventHotKeyRef?

    /// Wire up the read-aloud capability: the Services entry, the read-along queue,
    /// and the ⌃⇧V hotkey. The status item + menu are owned by the app coordinator.
    public func start() {
        SpeakController.shared = self
        setStatusIcon(watching: false)

        NSApp.servicesProvider = services
        NSUpdateDynamicServices()

        Speaker.shared.onQueueDrained = { [weak self] in self?.handleQueueDrained() }

        registerHotKey()
    }

    /// The read-aloud section of the shared menu. Rebuilt by the coordinator on demand.
    public func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        watchMenuItem = NSMenuItem(title: "Read Aloud — Watch Selections  ⌃⇧V", action: #selector(toggleCapture), keyEquivalent: "")
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

    // MARK: capture mode (the ⌃⇧V toggle)

    /// ⌃⇧V: start watching if idle, otherwise stop everything.
    @objc func toggleCapture() {
        if sessionActive {
            endSessionHard()
        } else {
            startCapture()
        }
    }

    private func startCapture() {
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
        // Honor the old muscle memory: if something is already selected, read it.
        captureCurrentSelection()
    }

    /// ✕ / Esc: stop watching for new highlights, but let the queue finish.
    func exitWatching() {
        guard captureMode else { return }
        captureMode = false
        removeMonitors()
        setStatusIcon(watching: false)
        watchMenuItem?.state = .off
        Overlay.shared.setWatching(false)
        if !Speaker.shared.isActive && Speaker.shared.pending == 0 {
            endSessionSoft()
        } else {
            Overlay.shared.setStatus("reading — will stop when done")
        }
    }

    /// ⌃⇧V again / ■: stop reading and close the bar.
    func endSessionHard() {
        cancelIdleClose()
        captureMode = false
        sessionActive = false
        removeMonitors()
        setStatusIcon(watching: false)
        watchMenuItem?.state = .off
        Speaker.shared.stop()
        Overlay.shared.close()
    }

    /// The queue finished on its own and we're no longer watching.
    private func endSessionSoft() {
        sessionActive = false
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
            Overlay.shared.finish()
        }
    }

    // MARK: one-shot reads (Services / menu) — unchanged behavior

    func readOneShot(_ text: String) {
        captureMode = false
        sessionActive = false
        removeMonitors()
        setStatusIcon(watching: false)
        watchMenuItem?.state = .off
        Overlay.shared.present(watching: false)
        Overlay.shared.center() // always start bottom-center
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

    // MARK: watching the user's highlights

    private func installMonitors() {
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.mouseDownPoint = NSEvent.mouseLocation
        }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self else { return }
            let up = NSEvent.mouseLocation
            let dragged = hypot(up.x - self.mouseDownPoint.x, up.y - self.mouseDownPoint.y) > 4
            // A drag is a sweep-select; clickCount ≥ 2 is a word/line double-
            // or triple-click. Plain single clicks aren't selections, so we
            // skip them and avoid spamming synthetic ⌘C.
            if dragged || event.clickCount >= 2 {
                self.captureCurrentSelection()
            }
        }
        registerEscapeHotKey()
    }

    private func removeMonitors() {
        for monitor in [mouseDownMonitor, mouseUpMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        mouseDownMonitor = nil
        mouseUpMonitor = nil
        unregisterEscapeHotKey()
    }

    private func captureCurrentSelection() {
        guard captureMode, !grabbing else { return }
        grabbing = true
        SelectionGrabber.grab { [weak self] text in
            guard let self else { return }
            self.grabbing = false
            guard self.captureMode else { return }
            let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != self.lastCaptured else { return }
            // If you dragged to *extend* the previous selection, only read the
            // newly added tail — don't re-read what's already queued.
            var toRead = trimmed
            if let last = self.lastCaptured, trimmed.hasPrefix(last) {
                let tail = String(trimmed.dropFirst(last.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if tail.isEmpty { self.lastCaptured = trimmed; return }
                toRead = tail
            }
            self.lastCaptured = trimmed
            self.cancelIdleClose() // a new highlight keeps the session alive
            Overlay.shared.present(watching: true)
            Speaker.shared.enqueue(toRead)
        }
    }

    private func setStatusIcon(watching: Bool) {
        onIcon?(watching ? "waveform.circle.fill" : "play.bubble")
    }

    // MARK: hotkey (⌃⇧V) via Carbon — no dependencies, works on every macOS.

    private func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        // One handler serves both hotkeys; dispatch on the registered id.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async {
                if id == 1 { SpeakController.shared.toggleCapture() }
                else if id == 2 { SpeakController.shared.exitWatching() }
            }
            return noErr
        }, 1, &eventType, nil, nil)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4C45_4C4F), id: 1) // "LELO"
        RegisterEventHotKey(UInt32(kVK_ANSI_V),
                            UInt32(controlKey | shiftKey),
                            hotKeyID,
                            GetApplicationEventTarget(),
                            0,
                            &hotKeyRef)
    }

    // While watching, Escape stops watching. A Carbon hotkey (like ⌃⇧V) is used
    // instead of an NSEvent key monitor because global key monitors need the
    // separate Input Monitoring permission — this needs nothing beyond what we
    // already have. It's only registered while watching, so Escape is normal
    // otherwise. (It does consume Escape while watching, which is the intent.)
    private func registerEscapeHotKey() {
        guard escHotKeyRef == nil else { return }
        let id = EventHotKeyID(signature: OSType(0x4C45_4C4F), id: 2)
        RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetApplicationEventTarget(), 0, &escHotKeyRef)
    }

    private func unregisterEscapeHotKey() {
        if let ref = escHotKeyRef {
            UnregisterEventHotKey(ref)
            escHotKeyRef = nil
        }
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
