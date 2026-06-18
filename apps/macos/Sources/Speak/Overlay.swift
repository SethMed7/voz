import AppKit

/// The read-along panel. Two modes:
///  • mini (default) — a small draggable player: waveform + play/pause + stop, so it stays out of
///    your way while you work. Click ⤢ to expand.
///  • expanded — the full transcript: click any selection to skip to it, scroll freely, voice menu.
/// It never steals focus, defaults to bottom-center each session, and auto-closes when done.
final class Overlay {
    static let shared = Overlay()

    enum Mode { case mini, expanded }
    /// A fresh session opens here. You press ⌃V to *see* your selections read back, so default to
    /// the expanded panel (transcript + read-along); ⤡ collapses to the mini player anytime.
    private let defaultMode: Mode = .expanded
    private var mode: Mode = .expanded

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

    // voz read-aloud — the dark identity: black surface, one electric-blue accent (brand: black +
    // blue). Matches the dictation pill so the two capabilities feel like one app. "It's reading"
    // is carried by MOTION (the animated waveform + play glyph), never a second hue — so the live
    // accent is the same electric blue.
    private let textHi = NSColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1)   // near-white, high-emphasis
    private let textLo = NSColor(srgbRed: 0.62, green: 0.66, blue: 0.72, alpha: 1)   // mist — secondary labels / placeholder
    private let accent = NSColor(srgbRed: 0x2E / 255.0, green: 0x74 / 255.0, blue: 0xFF / 255.0, alpha: 1) // electric blue — the one accent
    private let liveAccent = NSColor(srgbRed: 0x2E / 255.0, green: 0x74 / 255.0, blue: 0xFF / 255.0, alpha: 1) // live = same blue; motion signals it
    private let surface = NSColor(srgbRed: 0x16 / 255.0, green: 0x16 / 255.0, blue: 0x16 / 255.0, alpha: 0.97) // ink panel
    private let line = NSColor(srgbRed: 0.21, green: 0.22, blue: 0.24, alpha: 1)     // hairline border on dark
    private var softAccent: NSColor { accent.withAlphaComponent(0.16) }              // soft tint behind secondary icons
    private let bodyFont = NSFont.systemFont(ofSize: 15)
    private var boldFont: NSFont { NSFont.systemFont(ofSize: 15, weight: .heavy) }

    private let miniSize = NSSize(width: 220, height: 56)
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
        mode = defaultMode // next session reopens with the transcript visible
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
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: textLo,
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
        ts.addAttributes([.foregroundColor: NSColor.white, .backgroundColor: accent, .font: boldFont], range: abs)
        activeWord = abs
        autoScroll(abs)
    }

    private func baseAttrs(active: Bool) -> [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: active ? textHi : textLo]
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
    }

    func setStatus(_ text: String) {
        guard panel != nil else { return }
        statusLabel?.stringValue = text
    }

    func update(state: SpeakerState) {
        guard panel != nil else { return }
        switch state {
        case .preparing: statusLabel.stringValue = "preparing voice…"; setSpeaking(false)
        case .speaking: statusLabel.stringValue = "reading aloud"; setPlayGlyph(playing: true); setSpeaking(true)
        case .paused: statusLabel.stringValue = "paused"; setPlayGlyph(playing: false); setSpeaking(false)
        case .done: setPlayGlyph(playing: false); setSpeaking(false)
        case .failed(let message): statusLabel.stringValue = "error: \(message)"; setSpeaking(false)
        }
    }

    private func setPlayGlyph(playing: Bool) {
        let img = symbol(playing ? "pause.fill" : "play.fill")
        playButton?.image = img
        miniPlay?.image = img
    }
    private func setSpeaking(_ on: Bool) {
        speaking = on
        syncWaveform()
        // The play/pause control glows the live accent only while audio is actually playing (honest
        // "it's live"), back to the base accent when paused/idle/done. The pill background is layer-backed.
        let live = (on ? liveAccent : accent).cgColor
        miniPlay?.layer?.backgroundColor = live
        playButton?.layer?.backgroundColor = live
    }
    private func syncWaveform() { waveform?.setActive(speaking && mode == .mini) }

    func finish() {
        guard panel != nil else { return }
        statusLabel.stringValue = "done"
        setPlayGlyph(playing: false)
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
        mode = defaultMode
        let size = (mode == .mini) ? miniSize : expandedSize
        container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = surface.cgColor
        container.layer?.cornerRadius = 18
        container.layer?.borderWidth = 1
        container.layer?.borderColor = line.cgColor

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
        miniView.isHidden = (mode != .mini)
        expandedView.isHidden = (mode == .mini)

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true   // soft drop shadow so the card floats, not pasted onto the screen
        p.level = .floating
        p.contentView = container
        p.isMovableByWindowBackground = true // drag it anywhere
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + 28))
        }
        p.orderFrontRegardless()
        panel = p
    }

    private func buildMini() {
        // Minimal, premium: just the glowing waveform + play/pause + expand — like the dictation pill.
        // No wordmark, no badge, no stop button (Esc stops). The waveform has a fixed width so the
        // bars stay as crisp vertical capsules instead of stretching into ovals.
        waveform = WaveformView(bars: 7)
        waveform.barColor = liveAccent // animates only while audio plays — motion = live; rests flat

        miniPlay = circleButton("play.fill", action: #selector(togglePlay), color: accent, fg: .white, diameter: 36)
        let expandBtn = circleButton("arrow.up.left.and.arrow.down.right", action: #selector(expand),
                                     color: softAccent, fg: accent, diameter: 32)
        expandBtn.toolTip = "Show the text"

        let stack = NSStackView(views: [waveform, miniPlay, expandBtn])
        stack.orientation = .horizontal
        stack.spacing = 16
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        let v = NSView()
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            waveform.heightAnchor.constraint(equalToConstant: 20),
            waveform.widthAnchor.constraint(equalToConstant: 72),
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

        statusLabel = label("", size: 11, weight: .medium, color: textLo)
        statusLabel.alignment = .right
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.lineBreakMode = .byTruncatingTail

        playButton = circleButton("play.fill", action: #selector(togglePlay), color: accent, fg: .white, diameter: 34)
        let stopButton = circleButton("stop.fill", action: #selector(stopAll), color: softAccent, fg: accent, diameter: 32)
        stopButton.toolTip = "Stop  ·  Esc again"
        watchButton = circleButton("xmark", action: #selector(stopWatching), color: softAccent, fg: accent, diameter: 32)
        watchButton.toolTip = "Stop watching (keep reading what's queued)  ·  Esc"
        watchBadge = label("● watching", size: 11, weight: .bold, color: liveAccent) // live capture
        let collapseBtn = circleButton("arrow.down.right.and.arrow.up.left", action: #selector(collapse),
                                       color: softAccent, fg: accent, diameter: 32)
        collapseBtn.toolTip = "Minimize"

        voiceButton = circleButton("person.wave.2.fill", action: #selector(showVoiceMenu), color: softAccent, fg: accent, diameter: 32)
        voiceButton.toolTip = "Choose voice"

        let controls = NSStackView(views: [watchBadge, playButton, stopButton, watchButton, voiceButton, statusLabel, collapseBtn])
        controls.orientation = .horizontal
        controls.spacing = 14
        controls.alignment = .centerY
        controls.translatesAutoresizingMaskIntoConstraints = false

        let v = NSView()
        v.addSubview(scroll)
        v.addSubview(controls)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: v.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: pad),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -pad),
            controls.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            controls.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: pad),
            controls.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -pad),
            controls.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -18),
            controls.heightAnchor.constraint(equalToConstant: 36),
        ])
        expandedView = v
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        return l
    }

    /// An SF Symbol image at the app's control weight (template, tinted by the button).
    private func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .semibold) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
    }

    /// A round, layer-backed control with a centered SF Symbol. `accent` filled + white icon for the
    /// primary play/pause; a soft-blue tint + blue icon for secondary actions — clean, cohesive, modern.
    private func circleButton(_ symbolName: String, action: Selector, color: NSColor, fg: NSColor,
                              diameter: CGFloat = 34) -> NSButton {
        let b = NSButton(title: "", target: self, action: action)
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.backgroundColor = color.cgColor
        b.layer?.cornerRadius = diameter / 2
        b.contentTintColor = fg
        b.imagePosition = .imageOnly
        b.image = symbol(symbolName)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: diameter),
            b.heightAnchor.constraint(equalToConstant: diameter),
        ])
        return b
    }
}
