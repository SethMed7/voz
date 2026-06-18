import AppKit
import Carbon.HIToolbox

/// The single owner of the global Escape hotkey. Carbon won't let the same key be registered twice,
/// so the two capabilities can't each register Escape — they *claim* it instead: dictation while it
/// records, read-aloud while it watches. The most recent claim is the active handler; releasing it
/// falls back to the previous claimant. The Carbon hotkey is registered while any claim exists and
/// dropped when none remain. All calls are main-thread.
public final class EscapeKey {
    public static let shared = EscapeKey()
    private init() {}

    private struct Claim { let id: ObjectIdentifier; let handler: () -> Void }
    private var claims: [Claim] = []
    private var ref: EventHotKeyRef?
    private var installed = false

    private static let sig = OSType(0x766F_7A45) // "vozE"
    private static let hotKeyID: UInt32 = 99     // distinct from the Speak module's hotkey ids (1, 2)

    /// Route Escape to `onEscape` while `owner` holds the claim (most recent claim wins).
    public func claim(_ owner: AnyObject, _ onEscape: @escaping () -> Void) {
        let oid = ObjectIdentifier(owner)
        claims.removeAll { $0.id == oid }
        claims.append(Claim(id: oid, handler: onEscape))
        register()
    }

    /// Drop `owner`'s claim; Escape returns to the previous claimant, or stops being captured if none.
    public func release(_ owner: AnyObject) {
        let oid = ObjectIdentifier(owner)
        claims.removeAll { $0.id == oid }
        if claims.isEmpty { unregister() }
    }

    fileprivate func fire() { claims.last?.handler() }

    private func register() {
        guard ref == nil else { return }
        installHandler()
        let id = EventHotKeyID(signature: Self.sig, id: Self.hotKeyID)
        RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetApplicationEventTarget(), 0, &ref)
    }

    private func unregister() {
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
    }

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            // Only our Escape — every hotkey-pressed handler on the app target sees every hotkey, so
            // we MUST return eventNotHandledErr for anything else, or this handler swallows the event
            // and starves the ⌃V handler (returning noErr unconditionally silently killed ⌃V after the
            // first read-aloud session installed this handler).
            if hk.signature == EscapeKey.sig, hk.id == EscapeKey.hotKeyID {
                DispatchQueue.main.async { EscapeKey.shared.fire() }
                return noErr
            }
            return OSStatus(eventNotHandledErr)
        }, 1, &spec, nil, nil)
    }
}
