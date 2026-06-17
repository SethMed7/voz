import AppKit

/// A small local control panel for the dictionary: see where it lives (and point it elsewhere),
/// add words by hand, and remove any entry. Everything here is on-disk and local — no network.
/// Unlike the overlay/pill, this is a real window, so it activates the app while open.
final class Dashboard: NSObject, NSWindowDelegate {
    static let shared = Dashboard()

    private var window: NSWindow?
    private var listStack: NSStackView!
    private var pathLabel: NSTextField!
    private var fromField: NSTextField!
    private var toField: NSTextField!
    private var pronWordField: NSTextField!
    private var pronSayField: NSTextField!
    private var learnCheck: NSButton!
    private var engineLabel: NSTextField!
    private var sortedKeys: [String] = []
    private var sortedPronKeys: [String] = []
    private var sortedPendingKeys: [String] = []
    private var thresholdStepper: NSStepper!
    private var thresholdLabel: NSTextField!

    private var learnEnabled: (() -> Bool)?
    private var toggleLearn: (() -> Void)?

    private let bg = NSColor(srgbRed: 0x16 / 255.0, green: 0x16 / 255.0, blue: 0x16 / 255.0, alpha: 1)
    private let ink = NSColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1)
    private let muted = NSColor(srgbRed: 0.62, green: 0.66, blue: 0.72, alpha: 1)

    func open(learnEnabled: @escaping () -> Bool, toggleLearn: @escaping () -> Void) {
        self.learnEnabled = learnEnabled
        self.toggleLearn = toggleLearn
        if window == nil { build() }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: build

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 620),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "voz — Dictionary"
        w.titlebarAppearsTransparent = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.delegate = self

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading      // labels hug left; rows that need full width set their own
        root.distribution = .fill
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 18, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        root.addArrangedSubview(text("Dictionary", 16, .bold, ink))
        root.addArrangedSubview(text("Spelling fixes for dictation, and how read-aloud says a word — local, on your Mac.", 12, .regular, muted))

        pathLabel = text("", 11, .regular, muted)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let locRow = hrow([pathLabel, flexSpacer(),
                           button("Choose…", #selector(choose)),
                           button("Default", #selector(useDefault)),
                           button("Reveal", #selector(reveal))])

        engineLabel = text("", 12, .regular, muted)
        learnCheck = NSButton(checkboxWithTitle: "Learn from edits", target: self, action: #selector(toggleLearnTapped))
        learnCheck.contentTintColor = ink
        let setRow = hrow([engineLabel, flexSpacer(), learnCheck])

        thresholdStepper = NSStepper()
        thresholdStepper.minValue = 1; thresholdStepper.maxValue = 9
        thresholdStepper.integerValue = Lexicon.shared.learnThreshold
        thresholdStepper.valueWraps = false
        thresholdStepper.target = self; thresholdStepper.action = #selector(thresholdChanged)
        thresholdLabel = text("\(Lexicon.shared.learnThreshold)", 13, .semibold, ink)
        let learnRow = hrow([text("Learn a fix after", 12, .regular, muted), thresholdStepper, thresholdLabel,
                             text("correction(s)", 12, .regular, muted), flexSpacer()])

        fromField = inputField("misspelling")
        toField = inputField("correct spelling")
        let addRow = hrow([text("Fix", 12, .regular, muted), fromField, text("→", 13, .regular, muted), toField, button("Add", #selector(addTapped))])

        pronWordField = inputField("word")
        pronSayField = inputField("say it like")
        let pronRow = hrow([text("Say", 12, .regular, muted), pronWordField, text("→", 13, .regular, muted), pronSayField, button("Add", #selector(addPronTapped))])

        listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.distribution = .fill
        listStack.spacing = 6
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = listStack
        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            listStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        for row in [locRow, setRow, learnRow, addRow, pronRow, scroll] { root.addArrangedSubview(row) }

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = bg.cgColor
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            // Rows + list span the full content width.
            locRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            setRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            learnRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            addRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            pronRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        w.contentView = container
        window = w
    }

    // MARK: refresh

    private func refresh() {
        pathLabel?.stringValue = Lexicon.shared.fileURL.path
        engineLabel?.stringValue = "Engine: \(Transcribers.activeEngineName())"
        learnCheck?.state = (learnEnabled?() ?? true) ? .on : .off

        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Corrections (dictation): from -> to, with a Remove each.
        listStack.addArrangedSubview(sectionHeader("Corrections — applied to dictation"))
        let entries = Lexicon.shared.corrections.sorted { $0.key < $1.key }
        sortedKeys = entries.map { $0.key }
        if entries.isEmpty {
            listStack.addArrangedSubview(text("No corrections yet — add one above, or voz learns them after you make the same fix \(Lexicon.shared.learnThreshold)×.", 12, .regular, muted))
        } else {
            for (i, e) in entries.enumerated() {
                let r = hrow([text("\(e.key)  →  \(e.value)", 13, .regular, ink), flexSpacer(), removeButton(tag: i, #selector(removeTapped))])
                r.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
                listStack.addArrangedSubview(r)
            }
        }

        // Learning (pending): in-place fixes seen but not yet promoted to a rule, with their tally.
        listStack.addArrangedSubview(spacer(10))
        listStack.addArrangedSubview(sectionHeader("Learning — fixes seen, not yet rules"))
        let pend = Lexicon.shared.pending.sorted { $0.key < $1.key }
        sortedPendingKeys = pend.map { $0.key }
        if pend.isEmpty {
            listStack.addArrangedSubview(text("Nothing pending — correct a word in place and voz starts counting.", 12, .regular, muted))
        } else {
            for (i, e) in pend.enumerated() {
                let froms = e.value.froms.sorted().joined(separator: ", ")
                var line = "\(e.value.to)   (\(e.value.count) of \(Lexicon.shared.learnThreshold))"
                if !froms.isEmpty { line += "   ← \(froms)" }
                let r = hrow([text(line, 13, .regular, ink), flexSpacer(), removeButton(tag: i, #selector(removePendingTapped))])
                r.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
                listStack.addArrangedSubview(r)
            }
        }

        // Pronunciations (read-aloud): word -> say it like, with a Remove each.
        listStack.addArrangedSubview(spacer(10))
        listStack.addArrangedSubview(sectionHeader("Pronunciations — how read-aloud says a word"))
        let prons = Lexicon.shared.pronunciations.sorted { $0.key < $1.key }
        sortedPronKeys = prons.map { $0.key }
        if prons.isEmpty {
            listStack.addArrangedSubview(text("No pronunciations yet — add one above to fix how a name or term is read aloud.", 12, .regular, muted))
        } else {
            for (i, e) in prons.enumerated() {
                let r = hrow([text("\(e.key)  →  “\(e.value)”", 13, .regular, ink), flexSpacer(), removeButton(tag: i, #selector(removePronTapped))])
                r.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
                listStack.addArrangedSubview(r)
            }
        }
    }

    // MARK: actions

    @objc private func addTapped() {
        let from = fromField.stringValue.trimmingCharacters(in: .whitespaces)
        let to = toField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty, !to.isEmpty else { return }
        Lexicon.shared.learn(from: from, to: to)
        fromField.stringValue = ""; toField.stringValue = ""
        refresh()
    }

    @objc private func removeTapped(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < sortedKeys.count else { return }
        Lexicon.shared.forget(sortedKeys[sender.tag])
        refresh()
    }

    @objc private func addPronTapped() {
        let word = pronWordField.stringValue.trimmingCharacters(in: .whitespaces)
        let say = pronSayField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, !say.isEmpty else { return }
        Lexicon.shared.setPronunciation(word: word, say: say)
        pronWordField.stringValue = ""; pronSayField.stringValue = ""
        refresh()
    }

    @objc private func removePronTapped(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < sortedPronKeys.count else { return }
        Lexicon.shared.forgetPronunciation(sortedPronKeys[sender.tag])
        refresh()
    }

    @objc private func removePendingTapped(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < sortedPendingKeys.count else { return }
        Lexicon.shared.forgetPending(sortedPendingKeys[sender.tag])
        refresh()
    }

    @objc private func thresholdChanged() {
        Lexicon.shared.learnThreshold = thresholdStepper.integerValue
        thresholdLabel.stringValue = "\(thresholdStepper.integerValue)"
        refresh() // hint text references the threshold
    }

    @objc private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a dictionary file, or a folder to keep it in (stays on your Mac)."
        panel.prompt = "Use"
        if panel.runModal() == .OK, let url = panel.url { Lexicon.shared.setLocation(url); refresh() }
    }

    @objc private func useDefault() { Lexicon.shared.resetLocation(); refresh() }
    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([Lexicon.shared.ensureFileExists()]) }
    @objc private func toggleLearnTapped() { toggleLearn?(); refresh() }

    // MARK: tiny builders

    private func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        return l
    }

    private func inputField(_ placeholder: String) -> NSTextField {
        let f = NSTextField()
        f.placeholderString = placeholder
        f.font = .systemFont(ofSize: 13)
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return f
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    private func removeButton(tag: Int, _ action: Selector) -> NSButton {
        let b = button("Remove", action)
        b.tag = tag
        return b
    }

    private func sectionHeader(_ s: String) -> NSTextField {
        text(s, 11, .semibold, muted)
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let v = NSView()
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        return v
    }

    private func flexSpacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }

    private func hrow(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 8
        s.alignment = .centerY
        return s
    }
}
