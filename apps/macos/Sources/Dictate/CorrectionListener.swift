import ApplicationServices
import Foundation

/// Watches the field you dictated into for a few seconds after a paste. If you fix the spelling
/// of a single word that dictado typed (an in-place swap, e.g. "Miele" → "Myela"), it surfaces
/// that as a correction to learn. Everything is local: it reads the field's text via Accessibility
/// only to diff it, and only the corrected word PAIR is ever kept (on your OK) — never the
/// surrounding text. If the focused app doesn't expose its text to Accessibility, this does
/// nothing (no pill), so it degrades cleanly.
final class CorrectionListener {
    private var timer: Timer?
    private var element: AXUIElement?
    private var baseline: [String] = []     // field words right after the paste landed
    private var pasted: Set<String> = []    // lowercased words we inserted (only correct OUR output)
    private var deadline = Date.distantPast
    private var onDetect: ((String, String) -> Void)?
    private var lastSeen: String?           // field text at the previous poll (for the settle check)
    private var stableCount = 0             // consecutive polls with unchanged text

    /// Begin watching. Returns false if there's nothing watchable (AX text unavailable) so the
    /// caller knows not to bother. `onDetect(from, to)` fires at most once, on the main queue.
    @discardableResult
    func start(pasted text: String, onDetect: @escaping (String, String) -> Void) -> Bool {
        stop()
        guard AXIsProcessTrusted(),
              let el = Self.focusedElement(),
              let value = Self.value(of: el) else { return false }
        let words = Self.words(text).map { $0.lowercased() }
        guard !words.isEmpty else { return false }
        element = el
        baseline = Self.words(value)
        pasted = Set(words)
        lastSeen = value
        stableCount = 0
        self.onDetect = onDetect
        // Watch long enough to actually read the pasted text, notice a wrong word, and fix it.
        deadline = Date().addingTimeInterval(25)
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in self?.poll() }
        return true
    }

    func stop() {
        timer?.invalidate(); timer = nil
        element = nil; onDetect = nil; baseline = []; pasted = []
        lastSeen = nil; stableCount = 0
    }

    private func poll() {
        guard let el = element else { stop(); return }
        if Date() > deadline { stop(); return }
        guard let cur = Self.value(of: el) else { return }
        // Wait for the field to settle before judging the edit, so we capture the FINAL corrected
        // word, not a half-typed fragment ("Dhaval", not "De"). Two unchanged polls ≈ ~1.2s still.
        if cur == lastSeen { stableCount += 1 } else { lastSeen = cur; stableCount = 0; return }
        guard stableCount >= 2 else { return }
        let current = Self.words(cur)
        guard let (from, to) = Self.detectCorrection(baseline: baseline, current: current, pasted: pasted) else { return }
        let cb = onDetect
        stop()
        cb?(from, to)
    }

    // MARK: Accessibility

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var el: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &el) == .success,
              let e = el, CFGetTypeID(e) == AXUIElementGetTypeID() else { return nil }
        return (e as! AXUIElement)
    }

    /// Read the focused text as robustly as we can — many apps (incl. terminals like Ghostty) don't
    /// put the text on the focused element's AXValue directly, so fall back to its selected text and
    /// then to a text-bearing descendant. This is what lets edit-watching work beyond simple fields.
    private static func value(of el: AXUIElement) -> String? {
        if let s = stringAttr(el, kAXValueAttribute), !s.isEmpty { return s }
        if let s = stringAttr(el, kAXSelectedTextAttribute), !s.isEmpty { return s }
        return firstTextValue(in: el, depth: 0)
    }

    private static func stringAttr(_ el: AXUIElement, _ attr: String) -> String? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    /// Depth-bounded hunt for an AXTextArea/AXTextField descendant that exposes a value (terminals
    /// and many custom views nest their editable text below the "focused" container).
    private static func firstTextValue(in el: AXUIElement, depth: Int) -> String? {
        guard depth < 4 else { return nil }
        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children.prefix(24) {
            let role = stringAttr(child, kAXRoleAttribute)
            if role == (kAXTextAreaRole as String) || role == (kAXTextFieldRole as String),
               let s = stringAttr(child, kAXValueAttribute), !s.isEmpty { return s }
            if let s = firstTextValue(in: child, depth: depth + 1) { return s }
        }
        return nil
    }

    /// Diagnostic for `--axprobe`: describe the frontmost app's focused element + whether voz can
    /// read text from it (used to figure out edit-watching support in a given app, e.g. a terminal).
    static func probe() -> String {
        guard AXIsProcessTrusted() else { return "accessibility: NOT granted — grant voz first" }
        guard let el = focusedElement() else { return "no focused UI element (click into a text area, then re-run)" }
        let role = stringAttr(el, kAXRoleAttribute) ?? "?"
        let sub = stringAttr(el, kAXSubroleAttribute) ?? "-"
        var lines = ["focused role=\(role) subrole=\(sub)"]
        if let v = stringAttr(el, kAXValueAttribute) { lines.append("AXValue: \(v.count) chars — \"\(snippet(v))\"") }
        else { lines.append("AXValue: (none)") }
        if let s = stringAttr(el, kAXSelectedTextAttribute), !s.isEmpty { lines.append("AXSelectedText: \"\(snippet(s))\"") }
        if let d = firstTextValue(in: el, depth: 0) { lines.append("descendant text: \(d.count) chars — \"\(snippet(d))\"") }
        let readable = value(of: el) != nil
        lines.append(readable ? "→ voz CAN read text here (edit-watching should work)" : "→ voz CANNOT read text here (edit-watching won't work in this app)")
        return lines.joined(separator: "\n")
    }

    private static func snippet(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\n", with: "⏎").trimmingCharacters(in: .whitespaces)
        return one.count > 80 ? String(one.prefix(80)) + "…" : one
    }

    // MARK: diff

    static func words(_ s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "[A-Za-z][A-Za-z']*", options: []) else { return [] }
        let range = NSRange(s.startIndex..., in: s)
        return re.matches(in: s, range: range).compactMap {
            Range($0.range, in: s).map { String(s[$0]) }
        }
    }

    /// The edit between `baseline` (right after paste) and `current` (after you typed) is a
    /// correction only when EXACTLY one distinct word was removed and one added, the removed word
    /// was something we typed, and the two are spelling-close. Conservative on purpose — it should
    /// never learn a rephrase or a new sentence.
    static func detectCorrection(baseline: [String], current: [String], pasted: Set<String>) -> (String, String)? {
        let before = Set(baseline.map { $0.lowercased() })
        let after = Set(current.map { $0.lowercased() })
        let removed = before.subtracting(after)
        let added = after.subtracting(before)
        guard removed.count == 1, added.count == 1,
              let fromL = removed.first, let toL = added.first,
              pasted.contains(fromL),               // only fix words WE produced
              fromL.count >= 2, toL.count >= 2 else { return nil }
        let dist = levenshtein(fromL, toL)
        let maxLen = max(fromL.count, toL.count)
        guard dist >= 1, dist <= max(2, Int(ceil(Double(maxLen) * 0.5))) else { return nil }
        // Return original casing for display + storage.
        let fromOrig = baseline.first { $0.lowercased() == fromL } ?? fromL
        let toOrig = current.first { $0.lowercased() == toL } ?? toL
        return (fromOrig, toOrig)
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = x[i - 1] == y[j - 1]
                    ? prev[j - 1]
                    : Swift.min(prev[j - 1], prev[j], cur[j - 1]) + 1
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }
}
