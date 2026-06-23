import AppKit
import SwiftUI

/// Hosts the SwiftUI Insights dashboard in a single dark NSWindow — the one SwiftUI surface in an
/// otherwise-AppKit app. Mirrors the Dictionary window's dark chrome + accessory activation.
final class InsightsWindow {
    static let shared = InsightsWindow()
    private var window: NSWindow?
    private let nav = InsightsNav()

    func open(section: InsightsSection = .home) {
        if window == nil {
            let host = NSHostingView(rootView: InsightsRootView(store: InsightStore.shared, nav: nav))
            host.sizingOptions = [] // don't let the hosting view resize the window to its content
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 660),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "voz Insights"
            w.titleVisibility = .hidden // the sidebar already brands it; don't draw the title twice in the bar
            w.titlebarAppearsTransparent = true
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            w.contentView = host
            w.setFrameAutosaveName("voz.insights")
            w.center()
            window = w
        }
        nav.section = section
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
