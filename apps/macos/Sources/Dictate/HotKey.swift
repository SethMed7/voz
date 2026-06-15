import AppKit

/// Global hold-to-talk hotkey (⌃ + Fn) via NSEvent flag monitoring.
///
/// The Fn (🌐) key is NOT a Carbon modifier, so `RegisterEventHotKey` can't see
/// it — we watch `flagsChanged` events instead. Since this is hold-to-talk we
/// need BOTH edges: fire `onPress` the moment Control AND Fn are both down, and
/// `onRelease` the moment either lifts. A global monitor catches keys while
/// other apps are focused (the normal case); a local monitor covers our own
/// windows. Global keyboard monitoring needs Accessibility/Input-Monitoring
/// permission, which the app already requires to paste.
final class HotKey {
    static let shared = HotKey()

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var active = false

    /// Both must be held to arm. Fn shows up as `.function`.
    private let chord: NSEvent.ModifierFlags = [.control, .function]

    func register() {
        guard globalMonitor == nil, localMonitor == nil else { return } // idempotent: never stack monitors
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    /// Tear the monitors down so ⌃+Fn is fully inert (used when dictation is toggled off).
    /// Clears `active` so a half-held chord can't strand a press across a disable.
    func unregister() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        active = false
    }

    private func handle(_ event: NSEvent) {
        let down = event.modifierFlags.intersection(chord) == chord
        if down, !active {
            active = true
            DispatchQueue.main.async { self.onPress?() }
        } else if !down, active {
            active = false
            DispatchQueue.main.async { self.onRelease?() }
        }
    }
}
