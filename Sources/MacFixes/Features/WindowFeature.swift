import AppKit
import Carbon.HIToolbox

/// A target rectangle within a screen's visible frame (AX / top-left coords).
enum WindowPosition {
    case maximize, leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight, center

    func rect(in vf: CGRect) -> CGRect {
        let x = vf.minX, y = vf.minY, w = vf.width, h = vf.height
        switch self {
        case .maximize:    return vf
        case .leftHalf:    return CGRect(x: x,       y: y,       width: w / 2, height: h)
        case .rightHalf:   return CGRect(x: x + w/2, y: y,       width: w / 2, height: h)
        case .topHalf:     return CGRect(x: x,       y: y,       width: w,     height: h / 2)
        case .bottomHalf:  return CGRect(x: x,       y: y + h/2, width: w,     height: h / 2)
        case .topLeft:     return CGRect(x: x,       y: y,       width: w / 2, height: h / 2)
        case .topRight:    return CGRect(x: x + w/2, y: y,       width: w / 2, height: h / 2)
        case .bottomLeft:  return CGRect(x: x,       y: y + h/2, width: w / 2, height: h / 2)
        case .bottomRight: return CGRect(x: x + w/2, y: y + h/2, width: w / 2, height: h / 2)
        case .center:      return CGRect(x: x + w/6, y: y + h/6, width: w * 2/3, height: h * 2/3)
        }
    }
}

/// Window management: snapping/maximize hotkeys, drag-to-edge snapping, and
/// (via WindowObservers) red-X-quits-last-window and green-button maximize.
final class WindowFeature: Feature, @unchecked Sendable {
    private let defaults = UserDefaults.standard
    private var hotKeyIDs: [UInt32] = []
    private let snapper = SnapController()
    private let observers = WindowObservers()

    // Sub-toggles (default true except the intrusive ones).
    var snappingEnabled: Bool { get { flag("winSnapping", true) } set { setFlag("winSnapping", newValue) } }
    var dragSnapEnabled: Bool { get { flag("winDragSnap", true) } set { setFlag("winDragSnap", newValue) } }
    var closeQuitsEnabled: Bool { get { flag("winCloseQuits", false) } set { setFlag("winCloseQuits", newValue) } }
    var greenMaximizeEnabled: Bool { get { flag("winGreenMax", true) } set { setFlag("winGreenMax", newValue) } }

    private func flag(_ k: String, _ d: Bool) -> Bool { defaults.object(forKey: k) as? Bool ?? d }
    private func setFlag(_ k: String, _ v: Bool) { defaults.set(v, forKey: k); reload() }

    // Standard Rectangle-style shortcuts: Control+Option + key.
    private static let mods = UInt32(controlKey | optionKey)
    private var bindings: [(KeyCombo, WindowPosition)] {
        [
            (KeyCombo(keyCode: UInt32(kVK_Return),     modifiers: Self.mods), .maximize),
            (KeyCombo(keyCode: UInt32(kVK_LeftArrow),  modifiers: Self.mods), .leftHalf),
            (KeyCombo(keyCode: UInt32(kVK_RightArrow), modifiers: Self.mods), .rightHalf),
            (KeyCombo(keyCode: UInt32(kVK_UpArrow),    modifiers: Self.mods), .topHalf),
            (KeyCombo(keyCode: UInt32(kVK_DownArrow),  modifiers: Self.mods), .bottomHalf),
            (KeyCombo(keyCode: UInt32(kVK_ANSI_U),     modifiers: Self.mods), .topLeft),
            (KeyCombo(keyCode: UInt32(kVK_ANSI_I),     modifiers: Self.mods), .topRight),
            (KeyCombo(keyCode: UInt32(kVK_ANSI_J),     modifiers: Self.mods), .bottomLeft),
            (KeyCombo(keyCode: UInt32(kVK_ANSI_K),     modifiers: Self.mods), .bottomRight),
            (KeyCombo(keyCode: UInt32(kVK_ANSI_C),     modifiers: Self.mods), .center),
        ]
    }

    // MARK: Feature lifecycle

    @discardableResult
    func start() -> Bool {
        if !Permissions.hasAccessibility {
            Permissions.promptAccessibility()
            return false
        }
        reload()
        return true
    }

    func stop() {
        unregisterHotKeys()
        snapper.stop()
        observers.stop()
    }

    /// Apply current toggles.
    func reload() {
        if snappingEnabled { registerHotKeys() } else { unregisterHotKeys() }
        dragSnapEnabled ? snapper.start() : snapper.stop()
        observers.configure(closeQuits: closeQuitsEnabled, greenMaximize: greenMaximizeEnabled)
    }

    /// Move the focused window to a position (also used by the menu).
    static func apply(_ pos: WindowPosition) {
        guard let win = AXWindow.focusedWindow(), let frame = AXWindow.frame(of: win) else { return }
        let vf = AXWindow.axVisibleFrame(AXWindow.screen(forAX: frame))
        AXWindow.setFrame(win, pos.rect(in: vf))
    }

    private func registerHotKeys() {
        guard hotKeyIDs.isEmpty else { return }
        for (combo, pos) in bindings {
            hotKeyIDs.append(HotKeyCenter.shared.register(combo) { WindowFeature.apply(pos) })
        }
    }

    private func unregisterHotKeys() {
        hotKeyIDs.forEach { HotKeyCenter.shared.unregister($0) }
        hotKeyIDs = []
    }
}

/// Drag a window to a screen edge/corner to snap it, with a translucent preview.
/// Only used on the main run loop (mouse monitors and the feature's calls).
final class SnapController: @unchecked Sendable {
    private var dragMonitor: Any?
    private var upMonitor: Any?
    private var preview: NSWindow?
    private var pending: CGRect?   // AX-coords target for mouse-up
    private let threshold: CGFloat = 6

    func start() {
        guard dragMonitor == nil else { return }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            self?.dragged()
        }
        upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            self?.mouseUp()
        }
    }

    func stop() {
        [dragMonitor, upMonitor].forEach { if let m = $0 { NSEvent.removeMonitor(m) } }
        dragMonitor = nil; upMonitor = nil
        hidePreview()
    }

    private func dragged() {
        let cursor = NSEvent.mouseLocation  // bottom-left global coords
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) else {
            pending = nil; hidePreview(); return
        }
        let f = screen.frame
        let nearLeft   = cursor.x <= f.minX + threshold
        let nearRight  = cursor.x >= f.maxX - threshold
        let nearTop    = cursor.y >= f.maxY - threshold
        let nearBottom = cursor.y <= f.minY + threshold

        let pos: WindowPosition?
        switch true {
        case nearTop && nearLeft:     pos = .topLeft
        case nearTop && nearRight:    pos = .topRight
        case nearBottom && nearLeft:  pos = .bottomLeft
        case nearBottom && nearRight: pos = .bottomRight
        case nearTop:                 pos = .maximize
        case nearLeft:                pos = .leftHalf
        case nearRight:               pos = .rightHalf
        default:                      pos = nil
        }

        guard let pos else { pending = nil; hidePreview(); return }
        let vf = AXWindow.axVisibleFrame(screen)
        let axTarget = pos.rect(in: vf)
        pending = axTarget
        showPreview(AXWindow.toBottomLeft(axTarget))
    }

    private func mouseUp() {
        defer { pending = nil; hidePreview() }
        guard let target = pending, let win = AXWindow.focusedWindow() else { return }
        AXWindow.setFrame(win, target)
    }

    // Global monitors fire on the main thread, so the AppKit work is safe here.
    private func showPreview(_ rect: CGRect) {
        MainActor.assumeIsolated {
            if preview == nil {
                let w = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
                w.isOpaque = false
                w.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25)
                w.ignoresMouseEvents = true
                w.level = .floating
                w.hasShadow = false
                w.contentView?.wantsLayer = true
                w.contentView?.layer?.cornerRadius = 8
                preview = w
            }
            preview?.setFrame(rect, display: true)
            preview?.orderFront(nil)
        }
    }

    private func hidePreview() {
        MainActor.assumeIsolated { preview?.orderOut(nil) }
    }
}
