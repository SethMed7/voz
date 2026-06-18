import AppKit

/// The small, bottom-centered dictation indicator. Recording shows ONLY a live blue waveform that
/// moves with your voice — no text, no wordmark. On release the waveform goes flat and a spinner
/// appears to its right (processing); then it closes as the text pastes. Error/clipboard states use
/// a tiny text pill. Non-activating, so focus stays in the app you're dictating into.
final class Overlay {
    static let shared = Overlay()

    private var panel: NSPanel?
    private var waveformView: MicWaveformView?
    private var spinner: Spinner?
    private var autoCloseWork: DispatchWorkItem?

    private let ink = NSColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1)
    private let blue = NSColor(srgbRed: 0x2E / 255.0, green: 0x74 / 255.0, blue: 0xFF / 255.0, alpha: 1) // electric blue — the live waveform, accents
    private let muted = NSColor(srgbRed: 0.62, green: 0.66, blue: 0.72, alpha: 1)
    private let bg = NSColor(srgbRed: 0x16 / 255.0, green: 0x16 / 255.0, blue: 0x16 / 255.0, alpha: 0.97)
    private let stroke = NSColor(srgbRed: 0.21, green: 0.22, blue: 0.24, alpha: 1)

    private let pillHeight: CGFloat = 32
    private let waveSize = CGSize(width: 64, height: 20)

    // MARK: states

    /// Recording — a small rounded pill that is just the live waveform, reacting to your voice.
    func showListening() { mountWave(processing: false) }

    /// Feed the live mic level (0…1) to the recording waveform. No-op otherwise.
    func updateLevel(_ level: Float) { waveformView?.setLevel(CGFloat(level)) }

    /// Released — the waveform goes flat and a spinner spins on the right while we transcribe + polish.
    func showThinking() { mountWave(processing: true) }

    /// Pasted — the text in your app is its own confirmation, so just dismiss.
    func showTyped() { autoClose(after: 0.2) }

    /// Accessibility denied: text is on the clipboard. Tell the user to paste it.
    func showCopied(_ text: String) {
        presentText("⌘V to paste", detail: oneLine(text))
        autoClose(after: 3.0)
    }

    func flash(message: String) {
        presentText(message, detail: nil)
        autoClose(after: 1.4)
    }

    func close() {
        autoCloseWork?.cancel(); autoCloseWork = nil
        spinner = nil
        panel?.orderOut(nil); panel = nil
        waveformView = nil
    }

    // MARK: waveform pill (recording → processing)

    private func mountWave(processing: Bool) {
        autoCloseWork?.cancel(); autoCloseWork = nil

        // Recording starts a fresh waveform; processing reuses it so it eases flat with continuity.
        let wf: MicWaveformView
        if processing, let existing = waveformView {
            wf = existing
            wf.goFlat()
        } else {
            wf = MicWaveformView(bars: 7)
            wf.barColor = blue
        }
        wf.translatesAutoresizingMaskIntoConstraints = false
        wf.removeFromSuperview()
        waveformView = wf

        var views: [NSView] = [wf]
        if processing {
            let s = Spinner(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
            s.color = blue
            s.translatesAutoresizingMaskIntoConstraints = false
            spinner = s
            views.append(s)
        } else {
            spinner = nil
        }

        let rightInset: CGFloat = processing ? 10 : 12
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: rightInset)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let width = 12 + waveSize.width + (processing ? 8 + 16 : 0) + rightInset
        let content = makeCapsule(width: width, height: pillHeight)
        content.addSubview(stack)
        var cons = [
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            wf.widthAnchor.constraint(equalToConstant: waveSize.width),
            wf.heightAnchor.constraint(equalToConstant: waveSize.height),
        ]
        if let s = spinner {
            cons += [s.widthAnchor.constraint(equalToConstant: 16), s.heightAnchor.constraint(equalToConstant: 16)]
        }
        NSLayoutConstraint.activate(cons)
        install(content: content, width: width, height: pillHeight)
    }

    // MARK: text pill (errors / clipboard fallback)

    private func presentText(_ message: String, detail: String?) {
        close()
        let hasDetail = detail != nil && !(detail!.isEmpty)
        let msg = label(message, size: 12, weight: .medium, color: hasDetail ? blue : muted)
        var views: [NSView] = [msg]
        if hasDetail {
            let d = label(detail!, size: 12, weight: .regular, color: ink)
            d.maximumNumberOfLines = 1
            d.lineBreakMode = .byTruncatingTail
            d.setContentHuggingPriority(.defaultLow, for: .horizontal)
            d.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            views.append(d)
        }
        let width: CGFloat = hasDetail ? 460 : max(120, msg.intrinsicContentSize.width + 34)
        let height: CGFloat = 32
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = makeCapsule(width: width, height: height)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        install(content: content, width: width, height: height)
    }

    // MARK: plumbing

    private func makeCapsule(width: CGFloat, height: CGFloat) -> NSView {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true
        content.layer?.backgroundColor = bg.cgColor
        content.layer?.cornerRadius = height / 2 // full capsule — very rounded
        content.layer?.borderWidth = 1
        content.layer?.borderColor = stroke.cgColor
        return content
    }

    /// Install content into the (reused) panel for a smooth recording→processing transition.
    private func install(content: NSView, width: CGFloat, height: CGFloat) {
        let origin: NSPoint
        if let screen = Self.activeScreen() {
            let f = screen.visibleFrame
            origin = NSPoint(x: f.midX - width / 2, y: f.minY + 28)
        } else {
            origin = .zero
        }
        if let p = panel {
            p.contentView = content
            p.setFrame(NSRect(origin: origin, size: CGSize(width: width, height: height)), display: true, animate: false)
            return
        }
        let p = NSPanel(contentRect: NSRect(origin: origin, size: CGSize(width: width, height: height)),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.contentView = content
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        // Gentle pop-in: fade up with a small upward slide so the pill arrives, not blinks.
        p.alphaValue = 0
        p.setFrameOrigin(NSPoint(x: origin.x, y: origin.y - 10))
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
            p.animator().setFrameOrigin(origin)
        }
        panel = p
    }

    private func autoClose(after seconds: TimeInterval) {
        autoCloseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close() }
        autoCloseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// The screen the user is actually working on — the one under the pointer — so the pill appears
    /// near their context on multi-display setups, not always on the primary.
    static func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    private func oneLine(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.setContentHuggingPriority(.required, for: .horizontal)
        l.setContentCompressionResistancePriority(.required, for: .horizontal)
        return l
    }
}
