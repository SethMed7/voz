import AppKit

/// A live, voice-reactive equalizer for the dictation pill. Unlike Speak's
/// `WaveformView` (a fixed sine ripple that just signals "active"), this is
/// driven by the mic's real RMS level: bars leap when you speak and settle when
/// you pause. The audio callback only fires ~12×/s, so a ~60fps display timer
/// eases each bar toward the latest level — fast attack, slow release, like a VU
/// meter — so the motion looks fluid and alive rather than steppy.
final class MicWaveformView: NSView {
    var barColor: NSColor = NSColor(srgbRed: 0x22 / 255.0, green: 0xC7 / 255.0, blue: 0xA9 / 255.0, alpha: 1) {
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
    func setLevel(_ l: CGFloat) { target = min(1, max(0, l)) }

    /// Recording's over — collapse the bars to a flat line and stop reacting to input.
    func goFlat() { flat = true; target = 0 }

    private func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common) // keep ticking during window drags
        timer = t
    }

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
