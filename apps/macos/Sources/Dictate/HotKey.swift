import AppKit

/// Global dictation hotkey on the **Fn (🌐) key**, via NSEvent monitoring:
///   • Hold Fn — hold-to-talk: `onPress` once it's held past a short threshold, `onRelease` on lift.
///   • Double-tap Fn (alone, quickly) — `onDoubleTap`: a hands-free toggle (start, then stop).
///
/// Hold and double-tap share one key, so we disambiguate by timing: a quick tap is never a hold
/// (recording only starts after `holdDelay`), and two clean taps inside `tapWindow` are the double-tap.
/// `keyDown` is watched so Fn used as a shortcut modifier (Fn + arrow, Fn + Fkey, emoji picker) is told
/// apart from a deliberate bare tap/hold and never triggers dictation. Global monitoring needs
/// Accessibility, which the app already has.
///
/// Note: if macOS "Press 🌐 key to" is set to Start Dictation/Show Emoji, set it to **Do Nothing**
/// (System Settings ▸ Keyboard) so Fn is free for voz.
final class HotKey {
    static let shared = HotKey()

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onDoubleTap: (() -> Void)?

    private var monitors: [Any] = []
    private var active = false            // currently in a hold-to-talk recording
    private var fnWasDown = false
    private var tainted = false           // another key/modifier joined → Fn-as-shortcut, not dictation
    private var holdWork: DispatchWorkItem?

    // Double-tap bookkeeping (NSEvent.timestamp — monotonic seconds since boot).
    private var lastTapAt: TimeInterval = 0
    private var lastTapClean = false
    private var cooldownUntil: TimeInterval = 0   // ignore taps briefly after a toggle (the gesture's tail)
    private let holdDelay: TimeInterval = 0.18    // Fn must be held this long to start — distinguishes hold from tap
    private let tapWindow: TimeInterval = 0.4
    private let minTapGap: TimeInterval = 0.08    // two edges closer than this are chatter, not a deliberate double-tap

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

    /// Tear the monitors down so the hotkey is fully inert (used when dictation is toggled off).
    func unregister() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        cancelHold()
        active = false
        fnWasDown = false
        tainted = false
    }

    private func cancelHold() { holdWork?.cancel(); holdWork = nil }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            if fnWasDown { tainted = true; cancelHold() } // Fn + a key = a shortcut, never dictation
            return
        }
        // flagsChanged
        let flags = event.modifierFlags
        let fnNow = flags.contains(.function)
        let otherMods = !flags.intersection([.command, .option, .control, .shift, .capsLock]).isEmpty
        let t = event.timestamp

        if fnNow, !fnWasDown {                 // Fn pressed
            tainted = otherMods
            let gap = t - lastTapAt
            if !active, lastTapClean, gap > minTapGap, gap < tapWindow, t >= cooldownUntil {
                // Second clean tap → hands-free toggle; don't also start a hold.
                lastTapAt = 0; lastTapClean = false; cooldownUntil = t + 0.6
                cancelHold()
                DispatchQueue.main.async { self.onDoubleTap?() }
            } else {
                scheduleHold()                 // maybe a hold — confirm after the threshold
            }
        } else if fnNow, otherMods {           // another modifier joined while Fn is held → taint
            tainted = true
            cancelHold()
        } else if !fnNow, fnWasDown {          // Fn released
            cancelHold()
            if active {
                active = false
                DispatchQueue.main.async { self.onRelease?() }
            } else {
                // A tap (released before the hold threshold) — remember it for double-tap detection.
                lastTapAt = t
                lastTapClean = !tainted
            }
        }
        fnWasDown = fnNow
    }

    private func scheduleHold() {
        cancelHold()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.fnWasDown, !self.tainted, !self.active else { return }
            self.active = true
            self.onPress?()
        }
        holdWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: w)
    }
}
