import AppKit
import Carbon.HIToolbox

/// The phone as a touchpad and keyboard (`kdeconnect.mousepad.request`).
/// Turns the phone's packets into synthetic mouse and key events; needs the
/// Accessibility permission the app already uses for its event taps.
///
/// Modifiers follow the Windows-style setup this app assumes: the phone's
/// Ctrl becomes Command (so Ctrl+C copies), and its Windows/Super key
/// becomes Control.
final class ConnectInput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.filipkin.macfixes.connect.input", qos: .userInteractive)
    private var holding = false          // left button held (drag)
    private var scrollRemainder = 0.0

    func handle(_ p: ConnectPacket) {
        queue.async { [self] in
            guard AXIsProcessTrusted() else { return }
            if p.bool("singleclick") { click(.left, count: 1) }
            else if p.bool("doubleclick") { click(.left, count: 2) }
            else if p.bool("middleclick") { click(.center, count: 1) }
            else if p.bool("rightclick") { click(.right, count: 1) }
            else if p.bool("singlehold") { button(.left, down: true); holding = true }
            else if p.bool("singlerelease") { button(.left, down: false); holding = false }
            else if p.bool("scroll") { scroll(dx: number(p, "dx"), dy: number(p, "dy")) }
            else if let special = p.int64("specialKey"), special > 0 { key(special: Int(special), p) }
            else if let text = p.string("key"), !text.isEmpty { type(text, p) }
            else if p.body["dx"] != nil || p.body["dy"] != nil { move(dx: number(p, "dx"), dy: number(p, "dy")) }
        }
    }

    private func number(_ p: ConnectPacket, _ k: String) -> Double { (p.body[k] as? NSNumber)?.doubleValue ?? 0 }

    // MARK: Mouse

    private var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private func move(dx: Double, dy: Double) {
        var pt = location
        pt.x += dx
        pt.y += dy
        pt = clampToScreens(pt)
        let type: CGEventType = holding ? .leftMouseDragged : .mouseMoved
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func clampToScreens(_ pt: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let bounds = ids.map { CGDisplayBounds($0) }
        if bounds.contains(where: { $0.contains(pt) }) { return pt }
        // Off every screen: pull it back onto the nearest one.
        guard let nearest = bounds.min(by: { distance(pt, $0) < distance(pt, $1) }) else { return pt }
        return CGPoint(x: min(max(pt.x, nearest.minX), nearest.maxX - 1),
                       y: min(max(pt.y, nearest.minY), nearest.maxY - 1))
    }

    private func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }

    private func button(_ b: CGMouseButton, down: Bool, clickState: Int64 = 1) {
        let type: CGEventType
        switch (b, down) {
        case (.left, true): type = .leftMouseDown
        case (.left, false): type = .leftMouseUp
        case (.right, true): type = .rightMouseDown
        case (.right, false): type = .rightMouseUp
        case (_, true): type = .otherMouseDown
        case (_, false): type = .otherMouseUp
        }
        let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: b)
        e?.setIntegerValueField(.mouseEventClickState, value: clickState)
        e?.post(tap: .cghidEventTap)
    }

    private func click(_ b: CGMouseButton, count: Int) {
        for n in 1...count {
            button(b, down: true, clickState: Int64(n))
            button(b, down: false, clickState: Int64(n))
        }
    }

    /// Two-finger scroll on the phone. Sent as pixel deltas so it feels like
    /// a trackpad; the phone's dy is positive when the fingers move up, which
    /// with natural scrolling moves the content up.
    private func scroll(dx: Double, dy: Double) {
        let total = dy * 4 + scrollRemainder
        let lines = total.rounded(.towardZero)
        scrollRemainder = total - lines
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: Int32(-lines), wheel2: Int32(-dx * 4), wheel3: 0)?.post(tap: .cghidEventTap)
    }

    // MARK: Keyboard

    private func flags(_ p: ConnectPacket) -> CGEventFlags {
        var f: CGEventFlags = []
        if p.bool("ctrl") { f.insert(.maskCommand) }
        if p.bool("super") { f.insert(.maskControl) }
        if p.bool("alt") { f.insert(.maskAlternate) }
        if p.bool("shift") { f.insert(.maskShift) }
        return f
    }

    private func press(_ code: Int, _ f: CGEventFlags) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)
            e?.flags = f
            e?.post(tap: .cghidEventTap)
        }
    }

    /// Protocol special-key numbers (1 = Backspace … 32 = F12).
    private static let specials: [Int: Int] = [
        1: kVK_Delete, 2: kVK_Tab, 4: kVK_LeftArrow, 5: kVK_UpArrow, 6: kVK_RightArrow, 7: kVK_DownArrow,
        8: kVK_PageUp, 9: kVK_PageDown, 10: kVK_Home, 11: kVK_End, 12: kVK_Return, 13: kVK_ForwardDelete,
        14: kVK_Escape, 15: kVK_F13,
        21: kVK_F1, 22: kVK_F2, 23: kVK_F3, 24: kVK_F4, 25: kVK_F5, 26: kVK_F6,
        27: kVK_F7, 28: kVK_F8, 29: kVK_F9, 30: kVK_F10, 31: kVK_F11, 32: kVK_F12,
    ]

    private func key(special: Int, _ p: ConnectPacket) {
        guard let code = Self.specials[special] else { return }
        press(code, flags(p))
    }

    /// US-layout key codes, for shortcuts (a modifier plus a letter) where
    /// apps look at the key, not the character.
    private static let letters: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        " ": kVK_Space,
    ]

    private func type(_ text: String, _ p: ConnectPacket) {
        let f = flags(p)
        let shortcut = !f.subtracting(.maskShift).isEmpty
        if shortcut, text.count == 1, let c = text.lowercased().first, let code = Self.letters[c] {
            press(code, f)
            return
        }
        // Plain typing: send the characters themselves, so any language and
        // emoji work regardless of the Mac's keyboard layout.
        for ch in text {
            if ch == "\n" { press(kVK_Return, []); continue }
            let units = Array(String(ch).utf16)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                e?.post(tap: .cghidEventTap)
            }
        }
    }
}
