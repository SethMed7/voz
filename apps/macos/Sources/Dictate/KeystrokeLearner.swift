import AppKit
import Carbon.HIToolbox

/// Learns spelling corrections by WATCHING THE KEYSTROKES you type after a paste — no Accessibility
/// text-read needed, so it works where the AX approach can't (terminals like Ghostty / Claude Code).
///
/// voz knows exactly what it pasted and that the cursor sits at the end of it. From there it replays
/// your edits onto a shadow copy of the text: printable keys insert, Backspace/Delete remove, ◀ ▶
/// move the caret. When the text settles, it diffs the shadow against what was pasted; a clean
/// one-word swap of a word voz typed is a correction. It bails (no guess) on anything it can't track
/// — a mouse click, vertical/Home/End navigation, or a ⌘/⌃/⌥ shortcut — so it never invents an edit.
final class KeystrokeLearner {
    private var monitors: [Any] = []
    private var pasted: [Character] = []
    private var shadow: [Character] = []
    private var caret = 0
    private var bailed = false
    private var onDetect: ((String, String) -> Void)?
    private var settle: DispatchWorkItem?
    private var deadline: DispatchWorkItem?

    /// Begin watching. Returns false if input monitoring isn't available (Accessibility not granted),
    /// so the caller can hint. `onDetect(from, to)` fires at most once, on the main queue.
    @discardableResult
    func start(pasted text: String, onDetect: @escaping (String, String) -> Void) -> Bool {
        stop()
        guard AXIsProcessTrusted() else { return false }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        pasted = Array(t)
        shadow = pasted
        caret = shadow.count
        bailed = false
        self.onDetect = onDetect

        let key = NSEvent.EventTypeMask.keyDown
        if let g = NSEvent.addGlobalMonitorForEvents(matching: key, handler: { [weak self] e in self?.handleKey(e) }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: key, handler: { [weak self] e in self?.handleKey(e); return e }) { monitors.append(l) }
        // A click moves the caret invisibly — we can't track that, so stop guessing.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in self?.stop() }) { monitors.append(m) }

        let dl = DispatchWorkItem { [weak self] in self?.stop() }
        deadline = dl
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: dl)
        return true
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        settle?.cancel(); settle = nil
        deadline?.cancel(); deadline = nil
        onDetect = nil
        bailed = false
    }

    private func handleKey(_ e: NSEvent) {
        guard !bailed else { return }
        // Any ⌘/⌃/⌥ shortcut (select-all, word-jump, readline nav…) is untrackable → give up cleanly.
        if !e.modifierFlags.intersection([.command, .control, .option]).isEmpty { stop(); return }

        switch Int(e.keyCode) {
        case kVK_Delete: // Backspace
            if caret > 0 { shadow.remove(at: caret - 1); caret -= 1 }
        case kVK_ForwardDelete:
            if caret < shadow.count { shadow.remove(at: caret) }
        case kVK_LeftArrow:
            if caret > 0 { caret -= 1 }
        case kVK_RightArrow:
            if caret < shadow.count { caret += 1 }
        case kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_Escape:
            stop(); return // caret jumps we can't follow → give up
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab:
            evaluate(); return // committed — judge now
        default:
            guard let chars = e.characters, chars.count == 1, let c = chars.first,
                  c != "\r", c != "\n", c != "\t" else { return }
            shadow.insert(c, at: min(caret, shadow.count)); caret += 1
        }
        scheduleSettle()
    }

    private func scheduleSettle() {
        settle?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.evaluate() }
        settle = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w) // judge once typing pauses
    }

    private func evaluate() {
        guard !bailed, onDetect != nil else { return }
        let before = CorrectionListener.words(String(pasted))
        let after = CorrectionListener.words(String(shadow))
        let pastedSet = Set(before.map { $0.lowercased() })
        guard let (from, to) = CorrectionListener.detectCorrection(baseline: before, current: after, pasted: pastedSet) else {
            return // no clean single-word fix yet — keep watching until the deadline
        }
        let cb = onDetect
        stop()
        cb?(from, to)
    }
}
