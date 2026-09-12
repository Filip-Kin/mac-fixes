import Carbon.HIToolbox
import AppKit

/// A global keyboard shortcut: a virtual key code plus Carbon modifier flags.
/// Stored as plain integers so it round-trips through UserDefaults easily.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon flags: cmdKey, optionKey, controlKey, shiftKey

    /// Human-readable with Mac symbols, e.g. "⌘⇧4".
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += KeyCombo.keyName(keyCode)
        return s
    }

    /// Windows-style names, e.g. "Ctrl+Shift+4". Matches the modifier swap:
    /// ⌘→Ctrl, ⌃→Win, ⌥→Alt, ⇧→Shift. Falls back to Mac symbols when off.
    func display(windowsStyle: Bool) -> String {
        guard windowsStyle else { return display }
        var parts: [String] = []
        if modifiers & UInt32(cmdKey)     != 0 { parts.append("Ctrl") }
        if modifiers & UInt32(controlKey) != 0 { parts.append("Win") }
        if modifiers & UInt32(optionKey)  != 0 { parts.append("Alt") }
        if modifiers & UInt32(shiftKey)   != 0 { parts.append("Shift") }
        parts.append(KeyCombo.keyName(keyCode))
        return parts.joined(separator: "+")
    }

    static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_ANSI_0: return "0"; case kVK_ANSI_1: return "1"; case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"; case kVK_ANSI_4: return "4"; case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"; case kVK_ANSI_7: return "7"; case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"; case kVK_Return: return "↩"; case kVK_Escape: return "Esc"
        case kVK_Tab: return "⇥"; case kVK_Delete: return "⌫"; case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"; case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"; case kVK_DownArrow: return "↓"
        case kVK_Home: return "Home"; case kVK_End: return "End"
        case kVK_PageUp: return "PgUp"; case kVK_PageDown: return "PgDn"
        default:
            // Function keys, then letters and the rest via the keyboard layout.
            if let f = functionNumber(Int(code)) { return "F\(f)" }
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

extension KeyCombo {
    /// Modifier flags in AppKit form (for NSMenuItem display).
    var appKitModifiers: NSEvent.ModifierFlags {
        var m: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey)     != 0 { m.insert(.command) }
        if modifiers & UInt32(optionKey)  != 0 { m.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { m.insert(.control) }
        if modifiers & UInt32(shiftKey)   != 0 { m.insert(.shift) }
        return m
    }

    /// Modifier flags in CoreGraphics form (for synthesizing events).
    var cgFlags: CGEventFlags {
        var f: CGEventFlags = []
        if modifiers & UInt32(cmdKey)     != 0 { f.insert(.maskCommand) }
        if modifiers & UInt32(optionKey)  != 0 { f.insert(.maskAlternate) }
        if modifiers & UInt32(controlKey) != 0 { f.insert(.maskControl) }
        if modifiers & UInt32(shiftKey)   != 0 { f.insert(.maskShift) }
        return f
    }

    /// The key-equivalent string AppKit renders natively (e.g. F13 → "F13").
    var appKitKeyEquivalent: String {
        if let f = KeyCombo.functionNumber(Int(keyCode)) {
            // NSF1FunctionKey == 0xF704; the F-keys are sequential from there.
            return String(UnicodeScalar(0xF704 + (f - 1))!)
        }
        switch Int(keyCode) {
        case kVK_Space:  return " "
        case kVK_Return: return "\r"
        case kVK_Escape: return "\u{1b}"
        default:         return KeyCombo.keyName(keyCode).lowercased()
        }
    }

    static func functionNumber(_ code: Int) -> Int? {
        let map: [Int: Int] = [
            kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5, kVK_F6: 6,
            kVK_F7: 7, kVK_F8: 8, kVK_F9: 9, kVK_F10: 10, kVK_F11: 11, kVK_F12: 12,
            kVK_F13: 13, kVK_F14: 14, kVK_F15: 15, kVK_F16: 16, kVK_F17: 17,
            kVK_F18: 18, kVK_F19: 19, kVK_F20: 20,
        ]
        return map[code]
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
