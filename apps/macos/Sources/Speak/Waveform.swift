import AppKit

/// A tiny equalizer animation — a row of rounded bars that ripple while audio plays and rest flat
/// when paused/idle. Used in the minimized player as the "it's reading" indicator.
final class WaveformView: NSView {
    private var levels: [CGFloat]
    private var timer: Timer?
    private var phase: CGFloat = 0
    var barColor: NSColor = NSColor(srgbRed: 0x2E / 255.0, green: 0x74 / 255.0, blue: 0xFF / 255.0, alpha: 1) { didSet { needsDisplay = true } }

    init(bars: Int = 5) {
        levels = Array(repeating: 0.3, count: max(3, bars))
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func setActive(_ on: Bool) { on ? start() : stop() }

    private func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.phase += 0.45
            for i in self.levels.indices {
                self.levels[i] = 0.25 + 0.65 * (0.5 + 0.5 * sin(self.phase + CGFloat(i) * 0.8))
            }
            self.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .default) // .default lets the accessory's run loop go idle when not reading
        timer = t
    }

    private func stop() {
        timer?.invalidate(); timer = nil
        for i in levels.indices { levels[i] = 0.08 } // rest as a thin, flat equalizer line
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let n = levels.count
        let gap: CGFloat = 3
        let barW = max(2.5, (bounds.width - gap * CGFloat(n - 1)) / CGFloat(n))
        // Electric glow so the bars read as lit, matching the icon and the dictation pill.
        let glow = NSShadow()
        glow.shadowColor = barColor.withAlphaComponent(0.7)
        glow.shadowBlurRadius = 4
        glow.shadowOffset = .zero
        glow.set()
        barColor.setFill()
        for i in 0..<n {
            let h = max(3, levels[i] * bounds.height)
            let x = CGFloat(i) * (barW + gap)
            let y = (bounds.height - h) / 2
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barW, height: h),
                         xRadius: barW / 2, yRadius: barW / 2).fill()
        }
    }

    deinit { timer?.invalidate() }
}
