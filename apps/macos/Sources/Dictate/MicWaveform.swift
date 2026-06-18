import AppKit

/// A live, voice-reactive equalizer for the dictation pill. Unlike Speak's
/// `WaveformView` (a fixed sine ripple that just signals "active"), this is
/// driven by the mic's real RMS level: bars leap when you speak and settle when
/// you pause. The audio callback only fires ~12×/s, so a ~60fps display timer
/// eases each bar toward the latest level — fast attack, slow release, like a VU
/// meter — so the motion looks fluid and alive rather than steppy.
final class MicWaveformView: NSView {
    var barColor: NSColor = NSColor(srgbRed: 0x2E / 255.0, green: 0x74 / 255.0, blue: 0xFF / 255.0, alpha: 1) {
        didSet { needsDisplay = true }
    }

    private let barCount: Int
    private var levels: [CGFloat]   // current displayed bar heights, 0…1
    private var target: CGFloat = 0 // latest mic level, 0…1
    private var phase: CGFloat = 0
    private var timer: Timer?
    private var flat = false        // processing: bars ease to a flat line and stop reacting

    init(bars: Int = 7) {
        barCount = max(3, bars)
        levels = Array(repeating: 0.06, count: barCount)
        super.init(frame: .zero)
        wantsLayer = true
        start()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Feed a normalized mic level (0…1). Must be called on the main thread.
    func setLevel(_ l: CGFloat) {
        target = min(1, max(0, l))
        if timer == nil && !flat { start() } // re-arm if the view is reused after a stop
    }

    /// Recording's over — collapse the bars to a flat line, then STOP the per-frame loop. Static flat
    /// bars need no redraws and the spinner conveys "processing", so we don't burn 60fps for the whole
    /// multi-second transcribe + polish phase (the clearest energy waste in the app).
    func goFlat() {
        flat = true; target = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.stop() } // after the ease-out
    }

    private func start() {
        guard timer == nil else { return }
        // .default (not .common): a cosmetic equalizer needn't tick during a modal drag of its own tiny
        // pill, and a .common timer keeps the menu-bar accessory's run loop from ever going quiescent.
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .default)
        timer = t
    }

    private func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        phase += 0.42
        for i in levels.indices {
            let goal: CGFloat
            if flat {
                goal = 0.05 // collapse to a thin flat line
            } else {
                // Shape the live level with a traveling sine so the row ripples instead of moving as
                // one block; a wide peak-to-valley range makes it read as a lively sound wave.
                let ripple = 0.5 + 0.5 * sin(phase + CGFloat(i) * 1.15)
                goal = max(0.05, target * (0.22 + 0.78 * ripple))
            }
            // Snappy attack, slower release — a punchy VU-meter feel.
            let k: CGFloat = goal > levels[i] ? 0.6 : 0.16
            levels[i] += (goal - levels[i]) * k
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let n = levels.count
        let gap: CGFloat = 3
        let barW = max(2.5, (bounds.width - gap * CGFloat(n - 1)) / CGFloat(n))
        // Electric glow so the bars read as lit, matching the icon.
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

/// A small electric-blue spinner for the "processing" state — a stroked arc that rotates in place.
/// Custom (not NSProgressIndicator) so it matches the brand color, which the system spinner won't.
final class Spinner: NSView {
    var color: NSColor = NSColor(srgbRed: 0x2E / 255.0, green: 0x74 / 255.0, blue: 0xFF / 255.0, alpha: 1) {
        didSet { arc.strokeColor = color.cgColor }
    }
    private let arc = CAShapeLayer()

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        arc.fillColor = NSColor.clear.cgColor
        arc.strokeColor = color.cgColor
        arc.lineWidth = 2
        arc.lineCap = .round
        layer?.addSublayer(arc)
    }

    override func layout() {
        super.layout()
        let r = max(2, min(bounds.width, bounds.height) / 2 - 1.5)
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: r,
                    startAngle: 0, endAngle: .pi * 1.5, clockwise: false)
        arc.path = path
        arc.frame = bounds // anchorPoint defaults to center, so rotation spins in place
        if arc.animation(forKey: "spin") == nil {
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0
            a.toValue = -Double.pi * 2
            a.duration = 0.8
            a.repeatCount = .infinity
            arc.add(a, forKey: "spin")
        }
    }
}
