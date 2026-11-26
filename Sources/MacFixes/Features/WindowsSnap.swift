import AppKit
import Carbon.HIToolbox

// Windows-style keyboard snapping (Win + arrows) and the window picker that
// offers to fill the space left beside a snapped window.

extension WindowPosition {
    /// The snap position a window frame is sitting in, read from the frame
    /// itself (AX coords), or nil for a floating window. Widths are not
    /// compared, so an adaptive or divider-resized half still counts.
    static func of(_ f: CGRect, in vf: CGRect) -> WindowPosition? {
        let tol: CGFloat = 30
        let l = abs(f.minX - vf.minX) < tol, r = abs(f.maxX - vf.maxX) < tol
        let t = abs(f.minY - vf.minY) < tol, b = abs(f.maxY - vf.maxY) < tol
        let cornerSized = f.height >= vf.height * 0.35 && f.width >= vf.width * 0.15
        switch (l, r, t, b) {
        case (true, true, true, true):   return .maximize
        case (true, false, true, true):  return .leftHalf
        case (false, true, true, true):  return .rightHalf
        case (true, true, true, false):  return .topHalf
        case (true, true, false, true):  return .bottomHalf
        case (true, false, true, false): return cornerSized ? .topLeft : nil
        case (false, true, true, false): return cornerSized ? .topRight : nil
        case (true, false, false, true): return cornerSized ? .bottomLeft : nil
        case (false, true, false, true): return cornerSized ? .bottomRight : nil
        default:                         return nil
        }
    }
}

/// The frame each window had before it was snapped, so "restore" can put it
/// back. Main thread only.
enum SnapMemory {
    nonisolated(unsafe) private static var frames: [CGWindowID: CGRect] = [:]

    /// Call just before snapping `win`. A floating window's frame replaces the
    /// remembered one; a window that is already snapped keeps what it had.
    static func note(_ win: AXUIElement, frame: CGRect, in vf: CGRect) {
        guard WindowPosition.of(frame, in: vf) == nil else { return }
        let id = AXWindow.windowID(of: win)
        guard id != 0 else { return }
        if frames.count > 200 { frames = [:] }
        frames[id] = frame
    }

    static func take(_ win: AXUIElement) -> CGRect? {
        frames.removeValue(forKey: AXWindow.windowID(of: win))
    }
}

/// macOS's own shortcuts that sit on the same keys (Mission Control and
/// switching desktops are Control + arrows by default). They win over any app
/// shortcut, so they are switched off while Win + arrows is on and switched
/// back on afterwards. Only the ones actually bound to our keys are touched.
private enum SystemShortcuts {
    private typealias IsEnabled = @convention(c) (Int32) -> Bool
    private typealias SetEnabled = @convention(c) (Int32, Bool) -> Int32
    private typealias GetValue = @convention(c) (Int32, UnsafeMutablePointer<UInt16>,
                                                 UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt32>) -> Int32

    // Mission Control, application windows, move left/right a desktop, and
    // the Shift variant of each.
    private static let ids: [Int32] = [32, 33, 34, 35, 79, 80, 81, 82]
    private static let key = "winArrowDisabledSystemKeys"

    private static func sym<T>(_ name: String, _ type: T.Type) -> T? {
        guard let h = dlopen(nil, RTLD_NOW), let s = dlsym(h, name) else { return nil }
        return unsafeBitCast(s, to: type)
    }

    /// True if this shortcut is on and bound to one of the combos we register.
    private static func clashes(_ id: Int32) -> Bool {
        guard let isEnabled = sym("CGSIsSymbolicHotKeyEnabled", IsEnabled.self),
              let getValue = sym("CGSGetSymbolicHotKeyValue", GetValue.self), isEnabled(id) else { return false }
        var ch: UInt16 = 0, vk: UInt16 = 0, mods: UInt32 = 0
        guard getValue(id, &ch, &vk, &mods) == 0 else { return false }
        let m = CGEventFlags(rawValue: UInt64(mods))
            .intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand])
        let arrows = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow]
        if m == .maskControl { return arrows.contains(Int(vk)) }
        if m == [.maskControl, .maskShift] { return [kVK_LeftArrow, kVK_RightArrow].contains(Int(vk)) }
        return false
    }

    static func takeOver() {
        guard let setEnabled = sym("CGSSetSymbolicHotKeyEnabled", SetEnabled.self) else {
            trace("ArrowSnap", "cannot switch off macOS shortcuts: private call missing")
            return
        }
        // Kept on disk so they are still put back if the app dies in between.
        var off = Set(UserDefaults.standard.array(forKey: key) as? [Int] ?? [])
        for id in ids where clashes(id) {
            _ = setEnabled(id, false)
            off.insert(Int(id))
        }
        UserDefaults.standard.set(off.sorted(), forKey: key)
    }

    static func restore() {
        guard let off = UserDefaults.standard.array(forKey: key) as? [Int], !off.isEmpty else { return }
        if let setEnabled = sym("CGSSetSymbolicHotKeyEnabled", SetEnabled.self) {
            for id in off { _ = setEnabled(Int32(id), true) }
        }
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// Win + arrows, as on Windows. The Windows key sends Control after the
/// external-keyboard swap, so these are Control + arrow hotkeys.
///
///  - Left / Right: snap to that half; again moves the window to the facing
///    half of the next monitor that way; from the far half it restores.
///  - Up: maximize; a half becomes its top corner; a bottom corner its half.
///  - Down: restore a maximized window; a half becomes its bottom corner; a
///    top corner its half; anything else minimizes.
///  - Shift + Left / Right: move to the next monitor, same place on it.
final class ArrowSnap: @unchecked Sendable {
    enum Arrow { case left, right, up, down }
    private enum Outcome { case snap(WindowPosition, NSScreen), restore, minimize, nothing }

    var assist: SnapAssist?
    private var hotKeyIDs: [UInt32] = []

    func start() {
        guard hotKeyIDs.isEmpty else { return }
        SystemShortcuts.takeOver()
        let ctrl = UInt32(controlKey), ctrlShift = UInt32(controlKey | shiftKey)
        let keys: [(Int, Arrow)] = [(kVK_LeftArrow, .left), (kVK_RightArrow, .right),
                                    (kVK_UpArrow, .up), (kVK_DownArrow, .down)]
        for (code, arrow) in keys {
            hotKeyIDs.append(HotKeyCenter.shared.register(KeyCombo(keyCode: UInt32(code), modifiers: ctrl)) { [weak self] in
                MainActor.assumeIsolated { self?.move(arrow) }
            })
        }
        for (code, arrow) in keys.prefix(2) {
            hotKeyIDs.append(HotKeyCenter.shared.register(KeyCombo(keyCode: UInt32(code), modifiers: ctrlShift)) { [weak self] in
                MainActor.assumeIsolated { self?.moveToNextScreen(arrow) }
            })
        }
    }

    func stop() {
        hotKeyIDs.forEach { HotKeyCenter.shared.unregister($0) }
        hotKeyIDs = []
        SystemShortcuts.restore()
    }

    /// The next monitor in that direction, in left-to-right order, wrapping
    /// around. With one monitor this is the same monitor.
    private static func neighbour(of screen: NSScreen, _ arrow: Arrow) -> NSScreen {
        let order = NSScreen.screens.sorted {
            $0.frame.minX != $1.frame.minX ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY
        }
        guard let i = order.firstIndex(of: screen), order.count > 1 else { return screen }
        return order[(i + (arrow == .left ? -1 : 1) + order.count) % order.count]
    }

    /// The same relative place and size in another screen's usable area.
    private static func map(_ r: CGRect, from a: CGRect, to b: CGRect) -> CGRect {
        guard a.width > 0, a.height > 0 else { return b }
        let sx = b.width / a.width, sy = b.height / a.height
        return CGRect(x: b.minX + (r.minX - a.minX) * sx, y: b.minY + (r.minY - a.minY) * sy,
                      width: min(r.width * sx, b.width), height: min(r.height * sy, b.height))
    }

    private static func outcome(_ arrow: Arrow, from state: WindowPosition?, on screen: NSScreen) -> Outcome {
        let next = { neighbour(of: screen, arrow) }
        switch (arrow, state) {
        case (.left, .leftHalf):      return .snap(.rightHalf, next())
        case (.left, .topLeft):       return .snap(.topRight, next())
        case (.left, .bottomLeft):    return .snap(.bottomRight, next())
        case (.left, .rightHalf):     return .restore
        case (.left, .topRight):      return .snap(.topLeft, screen)
        case (.left, .bottomRight):   return .snap(.bottomLeft, screen)
        case (.left, _):              return .snap(.leftHalf, screen)

        case (.right, .rightHalf):    return .snap(.leftHalf, next())
        case (.right, .topRight):     return .snap(.topLeft, next())
        case (.right, .bottomRight):  return .snap(.bottomLeft, next())
        case (.right, .leftHalf):     return .restore
        case (.right, .topLeft):      return .snap(.topRight, screen)
        case (.right, .bottomLeft):   return .snap(.bottomRight, screen)
        case (.right, _):             return .snap(.rightHalf, screen)

        case (.up, .maximize):        return .nothing
        case (.up, .leftHalf):        return .snap(.topLeft, screen)
        case (.up, .rightHalf):       return .snap(.topRight, screen)
        case (.up, .bottomLeft):      return .snap(.leftHalf, screen)
        case (.up, .bottomRight):     return .snap(.rightHalf, screen)
        case (.up, _):                return .snap(.maximize, screen)

        case (.down, .maximize):      return .restore
        case (.down, .leftHalf):      return .snap(.bottomLeft, screen)
        case (.down, .rightHalf):     return .snap(.bottomRight, screen)
        case (.down, .topLeft):       return .snap(.leftHalf, screen)
        case (.down, .topRight):      return .snap(.rightHalf, screen)
        case (.down, _):              return .minimize
        }
    }

    @MainActor private func move(_ arrow: Arrow) {
        assist?.dismiss()
        guard let win = AXWindow.focusedWindow(), let frame = AXWindow.frame(of: win) else { return }
        let screen = AXWindow.screen(forAX: frame)
        let vf = AXWindow.axVisibleFrame(screen)
        switch Self.outcome(arrow, from: WindowPosition.of(frame, in: vf), on: screen) {
        case .snap(let pos, let target):
            SnapMemory.note(win, frame: frame, in: vf)
            AXWindow.setFrame(win, pos.rect(in: AXWindow.axVisibleFrame(target)))
            if pos != .maximize { assist?.offer(after: win, waitForRelease: true) }
        case .restore:
            let saved = SnapMemory.take(win) ?? WindowPosition.center.rect(in: vf)
            // Remembered on another monitor: restore to the same place on this one.
            let home = AXWindow.axVisibleFrame(AXWindow.screen(forAX: saved))
            AXWindow.setFrame(win, home == vf ? saved : Self.map(saved, from: home, to: vf))
        case .minimize:
            AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        case .nothing:
            break
        }
    }

    @MainActor private func moveToNextScreen(_ arrow: Arrow) {
        assist?.dismiss()
        guard let win = AXWindow.focusedWindow(), let frame = AXWindow.frame(of: win) else { return }
        let screen = AXWindow.screen(forAX: frame)
        let target = Self.neighbour(of: screen, arrow)
        guard target != screen else { return }
        AXWindow.setFrame(win, Self.map(frame, from: AXWindow.axVisibleFrame(screen),
                                        to: AXWindow.axVisibleFrame(target)))
    }
}

/// After a window is snapped to a half or corner, shows the Alt-Tab grid in
/// the space left empty, listing every other window; clicking one snaps it
/// into that space. Esc, any other key, or a click elsewhere closes it.
/// Main thread only.
final class SnapAssist: @unchecked Sendable {
    var enabled = false

    private let model = AltTabModel()
    private var panel: AltTabPanel?
    private var zones: [CGRect] = []            // AX coords, still to offer, in order
    private var placed: Set<CGWindowID> = []    // already snapped in this round
    private var monitors: [Any] = []
    private var releaseMonitor: Any?

    /// Offer the space beside `win`, which was just snapped. From the
    /// keyboard, wait until the Windows key (Control) is let go, as Windows does.
    @MainActor func offer(after win: AXUIElement, waitForRelease: Bool) {
        dismiss()
        guard enabled, let frame = AXWindow.frame(of: win) else { return }
        let vf = AXWindow.axVisibleFrame(AXWindow.screen(forAX: frame))
        guard let pos = WindowPosition.of(frame, in: vf) else { return }
        let others = AXWindow.onScreenWindowFrames(excluding: frame, intersecting: vf)
        zones = Self.emptyZones(beside: pos, frame: frame, in: vf, others: others)
        guard !zones.isEmpty else { return }
        placed = [AXWindow.windowID(of: win)]
        if waitForRelease, NSEvent.modifierFlags.contains(.control) {
            releaseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
                guard !e.modifierFlags.contains(.control) else { return }
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let m = self.releaseMonitor { NSEvent.removeMonitor(m); self.releaseMonitor = nil }
                    self.showNext()
                }
            }
        } else {
            showNext()
        }
    }

    @MainActor func dismiss() {
        if let m = releaseMonitor { NSEvent.removeMonitor(m); releaseMonitor = nil }
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        panel?.orderOut(nil)
        zones = []
        placed = []
        model.clear()
    }

    /// The regions beside a snapped window that no snapped window fills yet.
    private static func emptyZones(beside pos: WindowPosition, frame f: CGRect,
                                   in vf: CGRect, others: [CGRect]) -> [CGRect] {
        let snapped = others.filter {
            guard let p = WindowPosition.of($0, in: vf) else { return false }
            return p != .maximize
        }
        func inside(_ w: CGRect, _ zone: CGRect) -> Bool {
            let i = w.intersection(zone)
            return !i.isNull && i.width * i.height >= w.width * w.height * 0.85
        }
        // The far side: one full-height region, or its two corners when a
        // corner window already sits there.
        func farSide(_ r: CGRect) -> [CGRect] {
            guard snapped.contains(where: { inside($0, r) && $0.height < vf.height * 0.8 }) else { return [r] }
            return [CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height / 2),
                    CGRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2)]
        }
        let right = CGRect(x: f.maxX, y: vf.minY, width: vf.maxX - f.maxX, height: vf.height)
        let left = CGRect(x: vf.minX, y: vf.minY, width: f.minX - vf.minX, height: vf.height)
        let below = CGRect(x: f.minX, y: f.maxY, width: f.width, height: vf.maxY - f.maxY)
        let above = CGRect(x: f.minX, y: vf.minY, width: f.width, height: f.minY - vf.minY)
        let all: [CGRect]
        switch pos {
        case .leftHalf:    all = farSide(right)
        case .rightHalf:   all = farSide(left)
        case .topLeft:     all = [below] + farSide(right)
        case .bottomLeft:  all = [above] + farSide(right)
        case .topRight:    all = [below] + farSide(left)
        case .bottomRight: all = [above] + farSide(left)
        default:           all = []
        }
        return all.filter { zone in
            // Room for at least one card, and not already filled.
            guard zone.width >= 340, zone.height >= 300 else { return false }
            let filled = snapped.filter { inside($0, zone) }.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
            return filled < zone.width * zone.height * 0.85
        }
    }

    @MainActor private func showNext() {
        guard let zone = zones.first else { dismiss(); return }
        model.build(excluding: placed, currentSpaceOnly: true)
        model.selection = -1                    // nothing highlighted until hovered
        guard !model.windows.isEmpty else { dismiss(); return }
        model.onCommit = { [weak self] in MainActor.assumeIsolated { self?.pick() } }
        model.onCancel = { [weak self] in MainActor.assumeIsolated { self?.dismiss() } }
        let p = panel ?? AltTabPanel(model: model, fitted: true)
        panel = p
        p.setFrame(AXWindow.toBottomLeft(zone), display: true)
        p.orderFrontRegardless()
        guard monitors.isEmpty else { return }
        let close: (NSEvent) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown],
                                                     handler: close) { monitors.append(m) }
        // Clicks on our own windows (the taskbar), but not on the picker itself.
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] e in
            let onPicker = MainActor.assumeIsolated { e.window === self?.panel }
            if !onPicker { close(e) }
            return e
        }) { monitors.append(m) }
    }

    @MainActor private func pick() {
        guard let w = model.selected(), let el = w.element, let zone = zones.first else { dismiss(); return }
        zones.removeFirst()
        placed.insert(w.id)
        panel?.orderOut(nil)
        if let f = AXWindow.frame(of: el) {
            SnapMemory.note(el, frame: f, in: AXWindow.axVisibleFrame(AXWindow.screen(forAX: f)))
        }
        AXWindow.setFrame(el, zone)
        AXWindow.raise(el, pid: w.pid)
        showNext()
    }
}
