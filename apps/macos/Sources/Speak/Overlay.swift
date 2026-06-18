import AppKit

/// The read-along panel. Two modes:
///  • mini (default) — a small draggable player: waveform + play/pause + stop, so it stays out of
///    your way while you work. Click ⤢ to expand.
///  • expanded — the full transcript: click any selection to skip to it, scroll freely, voice menu.
/// It never steals focus, defaults to bottom-center each session, and auto-closes when done.
final class Overlay {
    static let shared = Overlay()

    enum Mode { case mini, expanded }
    private var mode: Mode = .mini

    private var panel: NSPanel?
    private var container: NSView!
    private var miniView: NSView!
    private var expandedView: NSView!

    private var transcriptView: TranscriptTextView!
    private var scrollView: NSScrollView!
    private var statusLabel: NSTextField!
    private var playButton: NSButton!      // expanded
    private var miniPlay: NSButton!        // mini
    private var watchButton: NSButton!
    private var watchBadge: NSTextField!
    private var miniBadge: NSTextField!
    private var voiceButton: NSButton!
    private var waveform: WaveformView!
    private var closeWork: DispatchWorkItem?
    private var speaking = false

    // Free-scroll: suppress auto-scroll for a few seconds after the user scrolls by hand.
    private var lastUserScroll = Date.distantPast
    private var programmaticUntil = Date.distantPast

    // Transcript bookkeeping.
    private var segmentRanges: [NSRange] = []
    private var activeSegment: Int?
    private var activeWord: NSRange?
    private var placeholderShown = false

    // voz read-aloud: warm light surface. Electric blue accents; live state is shown by the play
    // glyph + animated waveform (iris/jade now share the one blue hue).
    private let ink = NSColor(srgbRed: 0.165, green: 0.141, blue: 0.118, alpha: 1)
    private let dim = NSColor(srgbRed: 0.663, green: 0.608, blue: 0.537, alpha: 1)
    private let iris = NSColor(srgbRed: 0x2E / 255.0, green: 0x74 / 255.0, blue: 0xFF / 255.0, alpha: 1) // electric blue (brand/chrome)
    private let jade = NSColor(srgbRed: 0x2E / 255.0, green: 0x74 / 255.0, blue: 0xFF / 255.0, alpha: 1) // electric blue (live)
    private let sand = NSColor(srgbRed: 0.906, green: 0.847, blue: 0.769, alpha: 1)
    private let bg = NSColor(srgbRed: 0.984, green: 0.957, blue: 0.918, alpha: 0.98)
    private let bodyFont = NSFont.systemFont(ofSize: 15)
    private var boldFont: NSFont { NSFont.systemFont(ofSize: 15, weight: .heavy) }

    private let miniSize = NSSize(width: 380, height: 56)
    private let expandedSize = NSSize(width: 620, height: 360)
    private let pad: CGFloat = 24 // generous side padding for a cleaner card

    // MARK: lifecycle

    func present(watching: Bool) {
        closeWork?.cancel(); closeWork = nil
        if panel == nil { build() } // first build starts minimized, bottom-center
        setWatching(watching)
        panel?.orderFrontRegardless()
    }

    /// Snap back to bottom-center for the current mode — called when a new session starts.
    func center() {
        guard let panel, let screen = NSScreen.main else { return }
        let size = (mode == .mini) ? miniSize : expandedSize
        let f = screen.visibleFrame
        panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.minY + 28, width: size.width, height: size.height),
                       display: true)
    }

    func close() {
        closeWork?.cancel(); closeWork = nil
        waveform?.setActive(false)
        // The expanded build registers a boundsDidChange observer on the scroll
        // view's contentView; drop it so rebuilds don't accumulate stale entries
        // on this singleton.
        if let cv = scrollView?.contentView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: cv)
        }
        panel?.orderOut(nil)
        panel = nil
        mode = .mini // next session starts minimized again
    }

    // MARK: transcript

    func clearTranscript(placeholder: String = "") {
        segmentRanges.removeAll()
        activeSegment = nil
        activeWord = nil
        guard let ts = transcriptView?.textStorage else { return }
        ts.setAttributedString(NSAttributedString(string: ""))
        placeholderShown = false
        if !placeholder.isEmpty {
            ts.setAttributedString(NSAttributedString(string: placeholder, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: dim,
            ]))
            placeholderShown = true
        }
        transcriptView?.segmentRanges = segmentRanges
    }

    func addSegment(_ text: String) {
        guard let ts = transcriptView?.textStorage else { return }
        if placeholderShown { ts.setAttributedString(NSAttributedString(string: "")); placeholderShown = false }
        let prefix = segmentRanges.isEmpty ? "" : "\n\n"
        let start = ts.length + (prefix as NSString).length
        ts.append(NSAttributedString(string: prefix + text, attributes: baseAttrs(active: false)))
        segmentRanges.append(NSRange(location: start, length: (text as NSString).length))
        transcriptView?.segmentRanges = segmentRanges
    }

    /// Extend the last selection in place (used when a cut-off word is finished and merged).
    func appendToLastSegment(_ text: String) {
        guard let ts = transcriptView?.textStorage, let last = segmentRanges.indices.last else { return }
        ts.append(NSAttributedString(string: text, attributes: baseAttrs(active: activeSegment == last)))
        segmentRanges[last].length += (text as NSString).length
        transcriptView?.segmentRanges = segmentRanges
    }

    func setActiveSegment(_ index: Int) {
        guard let ts = transcriptView?.textStorage else { return }
        if let prev = activeSegment, prev < segmentRanges.count {
            ts.setAttributes(baseAttrs(active: false), range: segmentRanges[prev])
        }
        activeWord = nil
        activeSegment = (index >= 0 && index < segmentRanges.count) ? index : nil
        if let a = activeSegment {
            ts.setAttributes(baseAttrs(active: true), range: segmentRanges[a])
            autoScroll(segmentRanges[a])
        }
    }

    func highlightWord(segment index: Int, range: NSRange) {
        guard let ts = transcriptView?.textStorage,
              let a = activeSegment, a == index, a < segmentRanges.count else { return }
        let base = segmentRanges[a]
        guard range.location >= 0, range.location + range.length <= base.length else { return }
        let abs = NSRange(location: base.location + range.location, length: range.length)
        if let prev = activeWord, NSEqualRanges(prev, abs) { return }
        if let prev = activeWord { ts.setAttributes(baseAttrs(active: true), range: prev) }
        ts.addAttributes([.foregroundColor: NSColor.white, .backgroundColor: iris, .font: boldFont], range: abs)
        activeWord = abs
        autoScroll(abs)
    }

    private func baseAttrs(active: Bool) -> [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: active ? ink : dim]
    }

    /// Follow the read-along marker — but only if the user isn't scrolling by hand right now.
    private func autoScroll(_ range: NSRange) {
        guard Date().timeIntervalSince(lastUserScroll) > 5 else { return }
        programmaticUntil = Date().addingTimeInterval(0.4) // so our own scroll isn't read as a user scroll
        transcriptView.scrollRangeToVisible(range)
    }

    @objc private func clipBoundsChanged() {
        if Date() < programmaticUntil { return }
        lastUserScroll = Date()
    }

    // MARK: status / controls

    func setWatching(_ on: Bool) {
        guard panel != nil else { return }
        watchButton?.isHidden = !on
        watchBadge?.isHidden = !on
        miniBadge?.isHidden = !on
    }

    func setStatus(_ text: String) {
        guard panel != nil else { return }
        statusLabel?.stringValue = text
    }

    func update(state: SpeakerState) {
        guard panel != nil else { return }
        switch state {
        case .preparing: statusLabel.stringValue = "preparing voice…"; setSpeaking(false)
        case .speaking: statusLabel.stringValue = "reading aloud"; setPlayGlyph("❚❚"); setSpeaking(true)
        case .paused: statusLabel.stringValue = "paused"; setPlayGlyph("▶"); setSpeaking(false)
        case .done: setPlayGlyph("▶"); setSpeaking(false)
        case .failed(let message): statusLabel.stringValue = "error: \(message)"; setSpeaking(false)
        }
    }

    private func setPlayGlyph(_ g: String) { playButton?.title = g; miniPlay?.title = g }
    private func setSpeaking(_ on: Bool) {
        speaking = on
        syncWaveform()
        // The play/pause control turns jade only while audio is actually playing (honest "it's live"),
        // back to iris when paused/idle/done. The pillButton background is layer-backed.
        let live = (on ? jade : iris).cgColor
        miniPlay?.layer?.backgroundColor = live
        playButton?.layer?.backgroundColor = live
    }
    private func syncWaveform() { waveform?.setActive(speaking && mode == .mini) }

    func finish() {
        guard panel != nil else { return }
        statusLabel.stringValue = "done"
        setPlayGlyph("▶")
        setSpeaking(false)
        activeWord = nil
        scheduleClose(after: 1.4)
    }

    func flash(message: String) {
        present(watching: false)
        clearTranscript(placeholder: message)
        statusLabel?.stringValue = ""
        scheduleClose(after: 1.6)
    }

    private func scheduleClose(after seconds: TimeInterval) {
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close() }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    @objc private func showVoiceMenu() {
        let menu = NSMenu()
        for v in Voices.all {
            let it = NSMenuItem(title: v.label, action: #selector(pickVoice(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = v.id
            it.state = (v.id == Speaker.shared.voiceId) ? .on : .off
            menu.addItem(it)
        }
        if let btn = voiceButton {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: btn.bounds.height + 4), in: btn)
        }
    }
    @objc private func pickVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Speaker.shared.setVoice(id)
    }
    @objc private func togglePlay() { Speaker.shared.toggle() }
    @objc private func stopWatching() { SpeakController.shared.exitWatching() }
    @objc private func stopAll() { SpeakController.shared.endSessionHard() }
    @objc private func expand() { setMode(.expanded) }
    @objc private func collapse() { setMode(.mini) }

    private func setMode(_ m: Mode) {
        guard mode != m, let panel else { mode = m; return }
        mode = m
        let mini = (m == .mini)
        miniView.isHidden = !mini
        expandedView.isHidden = mini
        let old = panel.frame
        let size = mini ? miniSize : expandedSize
        panel.setFrame(NSRect(x: old.midX - size.width / 2, y: old.minY, width: size.width, height: size.height),
                       display: true, animate: false)
        syncWaveform()
    }

    // MARK: build

    private func build() {
        mode = .mini
        container = NSView(frame: NSRect(origin: .zero, size: miniSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = bg.cgColor
        container.layer?.cornerRadius = 18
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor(srgbRed: 0.910, green: 0.863, blue: 0.784, alpha: 1).cgColor

        buildExpanded()
        buildMini()
        container.addSubview(expandedView)
        container.addSubview(miniView)
        for v in [expandedView!, miniView!] {
            v.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: container.topAnchor),
                v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
        miniView.isHidden = false
        expandedView.isHidden = true

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: miniSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.contentView = container
        p.isMovableByWindowBackground = true // drag it anywhere
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - miniSize.width / 2, y: f.minY + 28))
        }
        p.orderFrontRegardless()
        panel = p
    }

    private func buildMini() {
        miniBadge = label("●", size: 12, weight: .bold, color: jade) // jade = a live capture is watching
        miniBadge.toolTip = "watching for highlights"
        waveform = WaveformView(bars: 7)
        waveform.barColor = jade // bars only animate while actually playing — jade = live audio
        waveform.translatesAutoresizingMaskIntoConstraints = false
        waveform.setContentHuggingPriority(.defaultLow, for: .horizontal)
        miniPlay = pillButton("▶", action: #selector(togglePlay), color: iris)
        let stop = pillButton("■", action: #selector(stopAll), color: sand, fg: ink)
        let expandBtn = pillButton("⤢", action: #selector(expand), color: sand, fg: ink)
        expandBtn.toolTip = "Show the text"

        let stack = NSStackView(views: [label("voz", size: 11, weight: .bold, color: iris),
                                        miniBadge, waveform, miniPlay, stop, expandBtn])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        let v = NSView()
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -18),
            stack.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            waveform.heightAnchor.constraint(equalToConstant: 20),
        ])
        miniView = v
    }

    private func buildExpanded() {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let tv = TranscriptTextView()
        tv.isEditable = false
        tv.isSelectable = false   // clicks skip; the scroll view still scrolls with the wheel
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 2, height: 6)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.onPick = { Speaker.shared.jumpTo(segment: $0) }
        scroll.documentView = tv
        transcriptView = tv
        scrollView = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)

        statusLabel = label("", size: 11, weight: .medium,
                            color: NSColor(srgbRed: 0.60, green: 0.541, blue: 0.467, alpha: 1))
        statusLabel.alignment = .right
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.lineBreakMode = .byTruncatingTail

        playButton = pillButton("▶", action: #selector(togglePlay), color: iris)
        let stopButton = pillButton("■", action: #selector(stopAll), color: sand, fg: ink)
        watchButton = pillButton("✕", action: #selector(stopWatching), color: sand, fg: ink)
        watchButton.toolTip = "Stop watching (keep reading what's queued)"
        watchBadge = label("● watching", size: 11, weight: .bold, color: jade) // jade = live capture
        let collapseBtn = pillButton("⤡", action: #selector(collapse), color: sand, fg: ink)
        collapseBtn.toolTip = "Minimize"

        voiceButton = pillButton("", action: #selector(showVoiceMenu), color: sand, fg: ink)
        voiceButton.toolTip = "Choose voice"
        if let img = NSImage(systemSymbolName: "person.wave.2.fill", accessibilityDescription: "Voice") {
            voiceButton.image = img
            voiceButton.imagePosition = .imageOnly
        } else { voiceButton.title = "🔊" }

        let controls = NSStackView(views: [label("voz", size: 11, weight: .bold, color: iris),
                                           watchBadge, playButton, stopButton, watchButton, voiceButton, statusLabel, collapseBtn])
        controls.orientation = .horizontal
        controls.spacing = 9
        controls.alignment = .centerY
        controls.translatesAutoresizingMaskIntoConstraints = false

        let v = NSView()
        v.addSubview(scroll)
        v.addSubview(controls)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: v.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: pad),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -pad),
            controls.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            controls.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: pad),
            controls.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -pad),
            controls.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -14),
            controls.heightAnchor.constraint(equalToConstant: 32),
        ])
        expandedView = v
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        return l
    }

    private func pillButton(_ title: String, action: Selector, color: NSColor, fg: NSColor = .white) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.backgroundColor = color.cgColor
        b.layer?.cornerRadius = 15
        b.contentTintColor = fg
        b.font = .systemFont(ofSize: 12, weight: .bold)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: 38),
            b.heightAnchor.constraint(equalToConstant: 30),
        ])
        return b
    }
}
