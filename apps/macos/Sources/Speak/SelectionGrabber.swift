import AppKit
import Carbon.HIToolbox

/// Grabs the current selection in whatever app is frontmost by briefly
/// borrowing the clipboard: save it, synthesize ⌘C, read, restore.
/// Posting key events needs the Accessibility permission — we prompt once.
enum SelectionGrabber {
    static func grab(completion: @escaping (String?) -> Void) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            completion(nil)
            return
        }
        // A grab is often triggered while the user is still holding the hotkey's modifiers
        // (⌃V, or a menu shortcut). If we synthesize ⌘C now, the held Control merges into it
        // → ⌃⌘C, which isn't Copy, so nothing lands on the pasteboard and we read back nil.
        // Wait (≤~0.4s) for a clean modifier state before copying.
        waitForModifiersToClear { performGrab(completion) }
    }

    /// Poll until no copy-poisoning modifier is physically held, then run `done`. Bails after
    /// `retries` so a stuck key can never hang the grab — a slightly dirty copy beats no copy.
    private static func waitForModifiersToClear(retries: Int = 20, _ done: @escaping () -> Void) {
        let poison: CGEventFlags = [.maskControl, .maskCommand, .maskShift, .maskAlternate]
        let held = CGEventSource.flagsState(.combinedSessionState).intersection(poison)
        if retries <= 0 || held.isEmpty {
            done()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                waitForModifiersToClear(retries: retries - 1, done)
            }
        }
    }

    private static func performGrab(_ completion: @escaping (String?) -> Void) {
        let pb = NSPasteboard.general
        let savedItems: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        }
        let before = pb.changeCount

        postCmdC()

        // Wait until the synthetic ⌘C actually lands (changeCount moves) before reading + restoring.
        // A fixed delay would let a slow Copy land *after* we restore and clobber the user's clipboard
        // with their selection; if it never lands (nothing selected), the restore is a harmless no-op.
        waitForCopy(pb: pb, before: before, retries: 24) {
            let text = pb.changeCount != before ? pb.string(forType: .string) : nil
            pb.clearContents()
            let restored = savedItems.map { dict -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in dict { item.setData(data, forType: type) }
                return item
            }
            if !restored.isEmpty { pb.writeObjects(restored) }
            completion(text)
        }
    }

    /// Poll (~25 ms × `retries`, ≈0.6 s ceiling) until the synthetic ⌘C changes the pasteboard, then run `done`.
    private static func waitForCopy(pb: NSPasteboard, before: Int, retries: Int, _ done: @escaping () -> Void) {
        if pb.changeCount != before || retries <= 0 { done(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
            waitForCopy(pb: pb, before: before, retries: retries - 1, done)
        }
    }

    private static func postCmdC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
