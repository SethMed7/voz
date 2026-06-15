import AppKit

/// The bottom-centered indicator shown while dictating. It is a pure STATE
/// indicator — it never shows your words (you don't need to watch them) — but it
/// always makes the mic state unambiguous: a pulsing dot while recording, a
/// brief "thinking" while transcribing, then "typed". Non-activating, so focus
/// stays in the app receiving the dictation.
final class Overlay {
    static let shared = Overlay()

    private var panel: NSPanel?
    private var dotLayer: CALayer?

    private let ink = NSColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1)
    private let iris = NSColor(srgbRed: 0x6E / 255.0, green: 0x56 / 255.0, blue: 0xE8 / 255.0, alpha: 1)
    private let jade = NSColor(srgbRed: 0x22 / 255.0, green: 0xC7 / 255.0, blue: 0xA9 / 255.0, alpha: 1)
    private let muted = NSColor(srgbRed: 0.62, green: 0.66, blue: 0.72, alpha: 1)
    private let bg = NSColor(srgbRed: 0x16 / 255.0, green: 0x16 / 255.0, blue: 0x16 / 255.0, alpha: 0.97)

    // MARK: states

    /// Recording — a pulsing jade dot. Stays up for the whole hold,
    /// through any pause (silence is not a stop). No words, ever.
    func showListening() {
        present(status: "listening", statusColor: muted, pulsing: true)
    }

    /// Transcribing the clip after release (usually well under a second).
    func showThinking() {
        present(status: "thinking", statusColor: muted, pulsing: false)
    }

    /// Pasted into the focused app — the text is already there, so just confirm.
    func showTyped() {
        present(status: "typed", statusColor: iris, pulsing: false)
        autoClose(after: 1.0)
    }

    /// Accessibility denied: text is on the clipboard, so echo it (head) so the
    /// user can confirm what was captured before pasting manually.
    func showCopied(_ text: String) {
        present(status: "copied · ⌘V to paste", statusColor: iris, pulsing: false, detail: oneLine(text))
        autoClose(after: 3.0)
    }

    func flash(message: String) {
        present(status: message, statusColor: muted, pulsing: false)
        autoClose(after: 1.4)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        dotLayer = nil
    }

    // MARK: rendering

    private func autoClose(after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.close() }
    }

    private func present(status: String, statusColor: NSColor, pulsing: Bool, detail: String? = nil) {
        close()

        let height: CGFloat = 44
        let hasDetail = detail != nil && !(detail!.isEmpty)
        let width: CGFloat = hasDetail ? 560 : 240

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true
        content.layer?.backgroundColor = bg.cgColor
        content.layer?.cornerRadius = 12
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor(srgbRed: 0.21, green: 0.22, blue: 0.24, alpha: 1).cgColor

        // The pulsing/solid status dot.
        let dotSize: CGFloat = 9
        let dotView = NSView(frame: .zero)
        dotView.wantsLayer = true
        dotView.translatesAutoresizingMaskIntoConstraints = false
        let dot = CALayer()
        dot.backgroundColor = jade.cgColor
        dot.frame = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
        dot.cornerRadius = dotSize / 2
        dotView.layer?.addSublayer(dot)
        dotLayer = dot
        if pulsing {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.25
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            dot.add(pulse, forKey: "pulse")
        }

        let brand = label("voz", size: 11, weight: .bold, color: iris)
        let statusLabel = label(status, size: 12, weight: .medium, color: statusColor)

        let leftStack = NSStackView(views: [dotView, brand, statusLabel])
        leftStack.orientation = .horizontal
        leftStack.spacing = 8
        leftStack.alignment = .centerY

        var views: [NSView] = [leftStack]
        if hasDetail {
            let detailLabel = label(detail!, size: 12, weight: .regular, color: ink)
            detailLabel.maximumNumberOfLines = 1
            detailLabel.lineBreakMode = .byTruncatingTail
            detailLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            views.append(detailLabel)
        }

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 14
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            dotView.widthAnchor.constraint(equalToConstant: dotSize),
            dotView.heightAnchor.constraint(equalToConstant: dotSize),
        ])

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.contentView = content
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient]

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - width / 2, y: f.minY + 28))
        }
        p.orderFrontRegardless()
        panel = p
    }

    private func oneLine(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
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
