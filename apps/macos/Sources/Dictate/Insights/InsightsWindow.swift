import AppKit
import SwiftUI

/// Hosts the SwiftUI Insights dashboard in a single dark NSWindow — the one SwiftUI surface in an
/// otherwise-AppKit app. Mirrors the Dictionary window's dark chrome + accessory activation.
final class InsightsWindow {
    static let shared = InsightsWindow()
    private var window: NSWindow?

    func open() {
        if window == nil {
            let host = NSHostingView(rootView: InsightsRootView(store: InsightStore.shared))
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "voz Insights"
            w.titlebarAppearsTransparent = true
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            w.contentView = host
            w.setFrameAutosaveName("voz.insights")
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
