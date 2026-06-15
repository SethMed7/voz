import AppKit
import Speak
import Dictate

/// voz — the voice layer for your Mac. One menu-bar app, two capabilities:
///   • Dictate — hold ⌃+Fn, speak, release; the cleaned text is typed where your cursor is.
///   • Read aloud — select text anywhere, press ⌃⇧V; voz reads it and follows along.
///
/// Each capability is a self-contained controller from its own module. The app owns the
/// single shared status item and routes each capability's icon/menu updates through here,
/// so the two never fight over the menu bar. Everything is 100% on-device.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let speak = SpeakController()
    private let dictate = DictateController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon("waveform")

        // Both capabilities share one menu-bar item; funnel their changes here.
        speak.onIcon = { [weak self] symbol in self?.setIcon(symbol) }
        dictate.onIcon = { [weak self] symbol in self?.setIcon(symbol) }
        speak.onMenuRebuild = { [weak self] in self?.rebuildMenu() }
        dictate.onMenuRebuild = { [weak self] in self?.rebuildMenu() }

        speak.start()
        dictate.start()
        rebuildMenu()
    }

    private func setIcon(_ symbol: String) {
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "voz")
    }

    /// One menu, two sections. Rebuilt on demand (e.g. when a capability toggles a checkmark).
    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false // dictation has disabled info rows

        let header = NSMenuItem(title: "voz", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        speak.menuItems().forEach { menu.addItem($0) }
        menu.addItem(.separator())
        dictate.menuItems().forEach { menu.addItem($0) }
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit voz", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }
}
