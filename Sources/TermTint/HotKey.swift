import AppKit
import Carbon.HIToolbox

/// System-wide hotkey. Carbon is still the only API that grabs a key
/// combination without a keyboard event tap, so it is what we use.
final class GlobalHotKey {

    static let tabKey = UInt32(kVK_Tab)
    static let option = UInt32(optionKey)
    static let optionShift = UInt32(optionKey | shiftKey)

    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handler: EventHandlerRef?

    private let id: UInt32
    private var reference: EventHotKeyRef?

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        Self.installHandlerIfNeeded()

        id = Self.nextID
        Self.nextID += 1

        let hotKeyID = EventHotKeyID(signature: OSType(0x54_54_4E_54), id: id) // 'TTNT'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, reference != nil else { return nil }

        Self.actions[id] = action
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        Self.actions[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return noErr }
            var id = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &id)
            guard status == noErr else { return noErr }
            GlobalHotKey.actions[id.id]?()
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
