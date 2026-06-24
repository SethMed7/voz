import AppKit
import Speak
import Dictate

// Headless smoke-test modes (CI / dev) come first, so they never spin up UI or
// touch permissions. Each capability owns its own flags; the first to claim the
// args wins. Everything below runs entirely on-device.
let args = CommandLine.arguments

if args.contains("--version") {
    print("voz \((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.7")"); exit(0)
}
if SpeakCLI.handle(args) { exit(0) }    // --speak "text"
if DictateCLI.handle(args) { exit(0) }  // --clean / --transcribe / --engine / --apply / --selftest

// Single instance: if voz is already running, surface that one and quit. This is the guard against
// duplication — you never get two menu-bar icons, or two sets of warm ASR/LLM servers competing over
// the one ~/.voz. (The CLI modes above already returned, so they're unaffected.)
if let bid = Bundle.main.bundleIdentifier {
    let mine = ProcessInfo.processInfo.processIdentifier
    if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
        .first(where: { $0.processIdentifier != mine }) {
        running.activate(options: [.activateIgnoringOtherApps])
        exit(0)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
app.run()
