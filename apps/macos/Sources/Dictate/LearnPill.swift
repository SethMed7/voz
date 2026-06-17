import AppKit

/// The little learn prompt: a rounded capsule that appears bottom-center when dictado notices
/// you fixed a word — "miele → Myela" between a ✕ (dismiss) and a ✓ (add to your dictionary).
/// Non-activating, so clicking it never steals focus from the app you're typing in.
final class LearnPill: NSObject {
    static let shared = LearnPill()

    private var panel: NSPanel?
    private var autoClose: DispatchWorkItem?
    private var onAccept: (() -> Void)?
    private var onRemove: (() -> Void)?

    private let ink = NSColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1)
    private let iris = NSColor(srgbRed: 0x6E / 255.0, green: 0x56 / 255.0, blue: 0xE8 / 255.0, alpha: 1) // voz brand accent (was dictado dusk-blue)
    private let muted = NSColor(srgbRed: 0.62, green: 0.66, blue: 0.72, alpha: 1)
    private let bg = NSColor(srgbRed: 0x1c / 255.0, green: 0x1c / 255.0, blue: 0x1e / 255.0, alpha: 0.98)
    private let circle = NSColor(srgbRed: 0.27, green: 0.28, blue: 0.30, alpha: 1)

    /// Show "from → to". ✓ runs onAccept (learn it); ✕ or a ~6s timeout dismisses without learning.
    func show(from: String, to: String, onAccept: @escaping () -> Void) {
        close()
        self.onAccept = onAccept

        let height: CGFloat = 44
        let dot: CGFloat = 30 // button diameter
        let center = label("\(from)  →  \(to)", size: 13, weight: .medium, color: ink)
        center.alignment = .center

        let reject = circleButton(symbol: "xmark", fg: ink, bgColor: circle, diameter: dot, action: #selector(rejectTapped))
        let accept = circleButton(symbol: "checkmark", fg: .white, bgColor: iris, diameter: dot, action: #selector(acceptTapped))

        let stack = NSStackView(views: [reject, center, accept])
        stack.orientation = .horizontal
        stack.spacing = 14
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 7, bottom: 0, right: 7)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let width = min(560, max(260, center.intrinsicContentSize.width + dot * 2 + 14 * 2 + 7 * 2 + 24))
        mountCapsule(stack: stack, width: width, height: height)

        let work = DispatchWorkItem { [weak self] in self?.close() } // timeout = dismiss, don't learn
        autoClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    /// Shown right after a word is added (same spot as dictation): "Saved 'Myela'" with a Remove
    /// button so you can undo it on the spot. Auto-dismisses after a few seconds.
    func showAdded(word: String, onRemove: @escaping () -> Void) {
        close()
        self.onRemove = onRemove

        let height: CGFloat = 44
        let badge = circleButton(symbol: "checkmark", fg: .white, bgColor: iris, diameter: 26, action: #selector(noop))
        badge.isEnabled = false
        let center = label("“\(word)” added to your dictionary", size: 13, weight: .medium, color: ink)
        let undo = textButton("Undo", action: #selector(removeTapped))

        let stack = NSStackView(views: [badge, center, undo])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let width = min(560, max(300, center.intrinsicContentSize.width + 26 + undo.intrinsicContentSize.width + 12 * 2 + 9 + 12 + 16))
        mountCapsule(stack: stack, width: width, height: height)
        addCountdownBar(width: width, height: height, duration: 4.0) // grace window; no Undo = the add stands

        let work = DispatchWorkItem { [weak self] in self?.close() }
        autoClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }

    /// A thin iris bar along the bottom that shrinks to empty over `duration` — a visible "you can
    /// still Undo" countdown. Sits within the capsule's flat middle so the rounded ends stay clean.
    private func addCountdownBar(width: CGFloat, height: CGFloat, duration: TimeInterval) {
        guard let content = panel?.contentView else { return }
        let radius = height / 2
        let barH: CGFloat = 2.5
        let bar = CALayer()
        bar.backgroundColor = iris.cgColor
        bar.cornerRadius = barH / 2
        bar.anchorPoint = CGPoint(x: 0, y: 0.5)
        bar.bounds = CGRect(x: 0, y: 0, width: max(0, width - 2 * radius), height: barH)
        bar.position = CGPoint(x: radius, y: barH + 1)
        content.layer?.addSublayer(bar)
        let anim = CABasicAnimation(keyPath: "transform.scale.x")
        anim.fromValue = 1.0
        anim.toValue = 0.0
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        bar.add(anim, forKey: "countdown")
    }

    /// Quiet, non-interactive progress while a fix is being tallied but isn't a rule yet:
    /// "learning 'Dhaval' · 1 of 2". Brief and muted — it teaches the frequency mechanic
    /// without nagging or asking for a tap. Auto-dismisses fast.
    func showProgress(word: String, count: Int, of threshold: Int) {
        close()
        let height: CGFloat = 38
        let badge = circleButton(symbol: "ear", fg: muted, bgColor: circle, diameter: 22, action: #selector(noop))
        badge.isEnabled = false
        let center = label("learning “\(word)” · \(count) of \(threshold)", size: 12, weight: .medium, color: muted)

        let stack = NSStackView(views: [badge, center])
        stack.orientation = .horizontal
        stack.spacing = 9
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let width = min(420, center.intrinsicContentSize.width + 22 + 9 + 10 + 14)
        mountCapsule(stack: stack, width: width, height: height)

        let work = DispatchWorkItem { [weak self] in self?.close() }
        autoClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    /// A one-off muted info note (e.g. "can't watch this app for edits"). Quiet, brief, no buttons.
    func showNote(_ message: String) {
        close()
        let height: CGFloat = 38
        let badge = circleButton(symbol: "info.circle", fg: muted, bgColor: circle, diameter: 22, action: #selector(noop))
        badge.isEnabled = false
        let center = label(message, size: 12, weight: .medium, color: muted)

        let stack = NSStackView(views: [badge, center])
        stack.orientation = .horizontal
        stack.spacing = 9
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let width = min(460, center.intrinsicContentSize.width + 22 + 9 + 10 + 14)
        mountCapsule(stack: stack, width: width, height: height)

        let work = DispatchWorkItem { [weak self] in self?.close() }
        autoClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: work)
    }

    func close() {
        autoClose?.cancel(); autoClose = nil
        panel?.orderOut(nil); panel = nil
        onAccept = nil; onRemove = nil
    }

    @objc private func acceptTapped() { let cb = onAccept; close(); cb?() }
    @objc private func rejectTapped() { close() }
    @objc private func removeTapped() { let cb = onRemove; close(); cb?() }
    @objc private func noop() {}

    /// Wrap a horizontal stack in the floating, non-activating capsule and show it bottom-center.
    private func mountCapsule(stack: NSStackView, width: CGFloat, height: CGFloat) {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true
        content.layer?.backgroundColor = bg.cgColor
        content.layer?.cornerRadius = height / 2 // full capsule
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor(srgbRed: 0.24, green: 0.25, blue: 0.27, alpha: 1).cgColor
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.contentView = content
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        if let screen = Overlay.activeScreen() {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - width / 2, y: f.minY + 28))
        }
        p.orderFrontRegardless()
        panel = p
    }

    /// A small text button (e.g. "Remove") tinted in the brand.
    private func textButton(_ title: String, action: Selector) -> NSButton {
        let b = NSButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.isBordered = false
        b.bezelStyle = .inline
        b.target = self
        b.action = action
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: iris,
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        ])
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    private func circleButton(symbol: String, fg: NSColor, bgColor: NSColor, diameter: CGFloat, action: Selector) -> NSButton {
        let b = NSButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.bezelStyle = .regularSquare
        b.isBordered = false
        b.title = ""
        b.target = self
        b.action = action
        b.wantsLayer = true
        b.layer?.backgroundColor = bgColor.cgColor
        b.layer?.cornerRadius = diameter / 2
        var cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        cfg = cfg.applying(.init(paletteColors: [fg]))
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)?
            .withSymbolConfiguration(cfg)
        b.imagePosition = .imageOnly
        b.contentTintColor = fg
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: diameter),
            b.heightAnchor.constraint(equalToConstant: diameter),
        ])
        return b
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return l
    }
}
