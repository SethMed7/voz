import AppKit
import Speak
import Dictate

/// voz — the voice layer for your Mac. One menu-bar app, two capabilities:
///   • Dictate — hold ⌃⌥, speak, release; the cleaned text is typed where your cursor is.
///   • Read aloud — select text anywhere, press ⌃V; voz reads it and follows along.
///
/// Each capability is a self-contained controller from its own module. The app owns the
/// single shared status item and routes each capability's icon/menu updates through here,
/// so the two never fight over the menu bar. Everything is 100% on-device.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let speak = SpeakController()
    private let dictate = DictateController()

    // Each capability reports the icon it wants plus a priority; the higher-priority one owns the
    // shared status item (so a hot mic is never masked by read-aloud). Both idle → the brand mark.
    private var speakIcon = (priority: 0, symbol: "waveform")
    private var dictateIcon = (priority: 0, symbol: "waveform")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        applyIcon()

        // Both capabilities share one menu-bar item; funnel their changes here.
        speak.onIcon = { [weak self] p, symbol in self?.speakIcon = (p, symbol); self?.applyIcon() }
        dictate.onIcon = { [weak self] p, symbol in self?.dictateIcon = (p, symbol); self?.applyIcon() }
        speak.onMenuRebuild = { [weak self] in self?.rebuildMenu() }
        dictate.onMenuRebuild = { [weak self] in self?.rebuildMenu() }

        speak.start()
        dictate.start()
        rebuildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictate.shutdown() // stop the warm ASR server we may have spawned
        speak.shutdown()   // stop any read + kill the Kokoro subprocess and delete its temp audio
    }

    /// Show the highest-priority capability's icon; when both are idle, show the brand mark.
    private func applyIcon() {
        let winner = dictateIcon.priority >= speakIcon.priority ? dictateIcon : speakIcon
        // Resting (both idle) → the voz brand V. Active → the live SF Symbol, so a hot mic or an
        // in-progress read still reads at a glance.
        if winner.priority == 0 {
            statusItem.button?.image = VozIcon.menuBar()
        } else {
            statusItem.button?.image = NSImage(systemSymbolName: winner.symbol, accessibilityDescription: "voz")
        }
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
