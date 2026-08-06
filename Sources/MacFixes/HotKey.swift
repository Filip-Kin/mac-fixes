import Carbon.HIToolbox
import AppKit

/// A global keyboard shortcut: a virtual key code plus Carbon modifier flags.
/// Stored as plain integers so it round-trips through UserDefaults easily.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon flags: cmdKey, optionKey, controlKey, shiftKey

    /// Human-readable, e.g. "⌘⇧4".
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += KeyCombo.keyName(keyCode)
        return s
    }

    static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_ANSI_0: return "0"; case kVK_ANSI_1: return "1"; case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"; case kVK_ANSI_4: return "4"; case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"; case kVK_ANSI_7: return "7"; case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"; case kVK_Return: return "↩"; case kVK_Escape: return "⎋"
        default:
            // Letters and the rest: best effort via the current keyboard layout.
            return layoutName(code) ?? "key\(code)"
        }
    }

    private static func layoutName(_ code: UInt32) -> String? {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let result = data.withUnsafeBytes { raw -> OSStatus in
            let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay),
                                  0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeys, chars.count, &length, &chars)
        }
        guard result == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// Registers global hotkeys via Carbon. No Accessibility permission needed.
final class HotKeyCenter {
    // Only touched on the main run loop (register + Carbon's event handler).
    nonisolated(unsafe) static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    private init() { install() }

    private func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            HotKeyCenter.shared.handlers[id.id]?()
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }

    @discardableResult
    func register(_ combo: KeyCombo, action: @escaping () -> Void) -> UInt32 {
        let id = nextID
        nextID += 1
        handlers[id] = action
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x4D464958), id: id) // 'MFIX'
        RegisterEventHotKey(combo.keyCode, combo.modifiers, hkID,
                            GetApplicationEventTarget(), 0, &ref)
        refs[id] = ref
        return id
    }

    func unregister(_ id: UInt32) {
        if let ref = refs[id] { UnregisterEventHotKey(ref) }
        refs[id] = nil
        handlers[id] = nil
    }
}
