import AppKit

/// Global dictation hotkeys via NSEvent monitoring:
///   • Hold ⌃ + ⌥ — hold-to-talk: `onPress` when both are down (any order), `onRelease` when either lifts.
///   • Double-tap ⌃ (alone, quickly) — `onDoubleTapControl`: a hands-free toggle (start, then stop).
///
/// The chord is modifier-only, so `RegisterEventHotKey` (which wants a real key) is a poor fit — we
/// watch `flagsChanged`. We also watch `keyDown` so a *clean* Control tap can be told apart from
/// Control used as a shortcut modifier (⌃C etc.): the double-tap only fires on a deliberate bare
/// double-tap, never on shortcuts. Global monitoring needs Accessibility, which the app already has.
final class HotKey {
    static let shared = HotKey()

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onDoubleTapControl: (() -> Void)?

    private var monitors: [Any] = []
    private var active = false

    /// Both must be held to arm, in any order. Option shows up as `.option`.
    private let chord: NSEvent.ModifierFlags = [.control, .option]

    // Double-tap-Control detection (timestamps are NSEvent.timestamp — monotonic seconds since boot).
    private var controlWasDown = false
    private var controlDownAt: TimeInterval = 0
    private var controlTainted = false   // another modifier joined, or a key was pressed → not a clean tap
    private var lastCleanTapAt: TimeInterval = 0
    private var cooldownUntil: TimeInterval = 0 // ignore taps briefly after a toggle (don't re-fire on the gesture's tail)
    private let tapWindow: TimeInterval = 0.4
    private let minTapGap: TimeInterval = 0.08  // two edges closer than this are key chatter, not a deliberate double-tap

    func register() {
        guard monitors.isEmpty else { return } // idempotent: never stack monitors
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e) }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e); return e }) {
            monitors.append(l)
        }
    }

    /// Tear the monitors down so the hotkeys are fully inert (used when dictation is toggled off).
    func unregister() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        active = false
        controlWasDown = false
        controlTainted = false
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            if controlWasDown { controlTainted = true } // a key pressed while Control is held → it's a shortcut
            return
        }
        // flagsChanged
        let flags = event.modifierFlags
        let controlNow = flags.contains(.control)
        let others = !flags.intersection([.command, .option, .shift, .function, .capsLock]).isEmpty

        // Hold chord (⌃ + ⌥).
        let down = flags.intersection(chord) == chord
        if down, !active {
            active = true
            DispatchQueue.main.async { self.onPress?() }
        } else if !down, active {
            active = false
            DispatchQueue.main.async { self.onRelease?() }
        }

        // Double-tap Control, pressed cleanly (no other modifier, no key) twice within the window.
        let t = event.timestamp
        if controlNow, !controlWasDown {
            controlDownAt = t
            controlTainted = others
        } else if controlNow, others {
            controlTainted = true
        } else if !controlNow, controlWasDown {
            // A clean tap = Control pressed+released alone, briefly, and not during a post-toggle cooldown.
            if !controlTainted, t - controlDownAt < tapWindow, t >= cooldownUntil {
                let gap = t - lastCleanTapAt
                if gap > minTapGap, gap < tapWindow {
                    lastCleanTapAt = 0
                    cooldownUntil = t + 0.6 // the next toggle needs a fresh deliberate double-tap
                    DispatchQueue.main.async { self.onDoubleTapControl?() }
                } else {
                    lastCleanTapAt = t
                }
            }
            controlDownAt = 0
        }
        controlWasDown = controlNow
    }
}
