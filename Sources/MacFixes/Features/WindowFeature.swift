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
    private let seams = SeamResizer()
    private let focus = FocusFollows()
    private let titlebar = TitlebarMaximize()

    // Sub-toggles (default true except the intrusive ones).
    var snappingEnabled: Bool { get { flag("winSnapping", true) } set { setFlag("winSnapping", newValue) } }
    // Off by default. Turning it on disables macOS's native edge-tiling (so the
    // two don't fight) and turns it back on when disabled. Our snap is adaptive.
    var dragSnapEnabled: Bool {
        get { flag("winDragSnap", false) }
        set {
            defaults.set(newValue, forKey: "winDragSnap")
            setNativeTiling(enabled: !newValue)
            reload()
        }
    }

    /// Enable or disable macOS's built-in drag-to-edge tiling.
    private func setNativeTiling(enabled: Bool) {
        let domain = "com.apple.WindowManager"
        for key in ["EnableTilingByEdgeDrag", "EnableTopTilingByEdgeDrag", "EnableTilingOptionAccelerator"] {
            if enabled {
                run(["/usr/bin/defaults", "delete", domain, key])          // restore default (on)
            } else {
                run(["/usr/bin/defaults", "write", domain, key, "-bool", "false"])
            }
        }
        run(["/usr/bin/killall", "WindowManager"])
    }

    private func run(_ argv: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        try? p.run(); p.waitUntilExit()
    }
    var closeQuitsEnabled: Bool { get { flag("winCloseQuits", false) } set { setFlag("winCloseQuits", newValue) } }
    var dividerResizeEnabled: Bool { get { flag("winDividerResize", true) } set { setFlag("winDividerResize", newValue) } }
    var titlebarMaximizeEnabled: Bool { get { flag("winTitlebarMax", false) } set { setFlag("winTitlebarMax", newValue) } }
    var focusFollowsEnabled: Bool { get { flag("winFocusFollows", false) } set { setFlag("winFocusFollows", newValue) } }
    var focusRaises: Bool { get { flag("winFocusRaises", true) } set { setFlag("winFocusRaises", newValue) } }

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
        seams.stop()
        focus.stop()
        titlebar.stop()
        observers.stop()
    }

    /// Apply current toggles.
    func reload() {
        if snappingEnabled { registerHotKeys() } else { unregisterHotKeys() }
        dragSnapEnabled ? snapper.start() : snapper.stop()
        if dividerResizeEnabled { seams.start() } else { seams.stop() }
        focus.raise = focusRaises
        if focusFollowsEnabled { focus.start() } else { focus.stop() }
        titlebarMaximizeEnabled ? titlebar.start() : titlebar.stop()
        observers.configure(closeQuits: closeQuitsEnabled)
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
    private var pending: CGRect?            // AX-coords target for mouse-up
    private var pendingWindow: AXUIElement? // the window being dragged
    private let threshold: CGFloat = 6
    // The top (maximize) zone is deeper — it is the one people aim for most, and
    // a fast flick to the top pins the cursor at the edge a little short of it.
    private let topThreshold: CGFloat = 44
    // The drag must move this far before snapping arms, so a click with a little
    // jitter (e.g. selecting a browser tab near the top) is not read as a drag.
    private let minDrag: CGFloat = 40
    private var dragOrigin: CGPoint?
    private var dragMoved = false

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
        let cursor = NSEvent.mouseLocation
        if dragOrigin == nil { dragOrigin = cursor }
        if let o = dragOrigin, hypot(cursor.x - o.x, cursor.y - o.y) > minDrag { dragMoved = true }
        guard dragMoved, let (target, win) = evaluate(at: cursor) else {
            pending = nil; pendingWindow = nil; hidePreview(); return
        }
        pending = target
        pendingWindow = win
        showPreview(AXWindow.toBottomLeft(target))
    }

    /// The snap zone for a cursor position, if any.
    private func zone(_ cursor: CGPoint, _ screen: NSScreen) -> WindowPosition? {
        let f = screen.frame
        let nearLeft   = cursor.x <= f.minX + threshold
        let nearRight  = cursor.x >= f.maxX - threshold
        let nearTop    = cursor.y >= f.maxY - topThreshold
        let nearBottom = cursor.y <= f.minY + threshold
        switch true {
        case nearTop && nearLeft:     return .topLeft
        case nearTop && nearRight:    return .topRight
        case nearBottom && nearLeft:  return .bottomLeft
        case nearBottom && nearRight: return .bottomRight
        case nearTop:                 return .maximize
        case nearLeft:                return .leftHalf
        case nearRight:               return .rightHalf
        default:                      return nil
        }
    }

    /// The AX target rect and window for a cursor position, or nil if it is not
    /// in a snap zone. Recomputed fresh so a fast flick that never fired a drag
    /// event at the edge still snaps on release.
    private func evaluate(at cursor: CGPoint) -> (CGRect, AXUIElement)? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) ?? NSScreen.main,
              let pos = zone(cursor, screen),
              let win = AXWindow.frontmostWindow() else { return nil }
        let vf = AXWindow.axVisibleFrame(screen)
        let occupied = AXWindow.onScreenWindowFrames(excluding: AXWindow.frame(of: win), intersecting: vf)
        return (Self.adaptiveTarget(pos, vf: vf, occupied: occupied), win)
    }

    /// Fill the space left by other windows: left/right take the gap up to the
    /// nearest opposite-side window (else half); corners take that gap width and
    /// half the height.
    static func adaptiveTarget(_ pos: WindowPosition, vf: CGRect, occupied: [CGRect]) -> CGRect {
        let minW = vf.width * 0.15
        let edgeTol: CGFloat = 12
        let tall = vf.height * 0.8
        // A window forms a fill boundary only if it is itself snapped to that
        // side — it touches the edge and is near full height. Floating windows
        // sitting in the middle of the screen are ignored.
        let rightBoundary = occupied
            .filter { $0.midX > vf.midX && $0.height >= tall && abs($0.maxX - vf.maxX) < edgeTol }
            .map(\.minX).min() ?? vf.midX
        let leftBoundary = occupied
            .filter { $0.midX < vf.midX && $0.height >= tall && abs($0.minX - vf.minX) < edgeTol }
            .map(\.maxX).max() ?? vf.midX

        switch pos {
        case .maximize:
            return vf
        case .leftHalf, .topLeft, .bottomLeft:
            let w = max(minW, min(rightBoundary - vf.minX, vf.width))
            let h = pos == .leftHalf ? vf.height : vf.height / 2
            let y = pos == .bottomLeft ? vf.midY : vf.minY
            return CGRect(x: vf.minX, y: y, width: w, height: h)
        case .rightHalf, .topRight, .bottomRight:
            let w = max(minW, min(vf.maxX - leftBoundary, vf.width))
            let h = pos == .rightHalf ? vf.height : vf.height / 2
            let y = pos == .bottomRight ? vf.midY : vf.minY
            return CGRect(x: vf.maxX - w, y: y, width: w, height: h)
        default:
            return pos.rect(in: vf)
        }
    }

    private func mouseUp() {
        let target = pending
        let win = pendingWindow
        pending = nil; pendingWindow = nil
        dragOrigin = nil; dragMoved = false
        hidePreview()
        guard let target, let win else { return }
        // Apply just after the drag finalizes, or the release overrides it.
        let rawInt = Int(bitPattern: Unmanaged.passRetained(win).toOpaque())
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let w = Unmanaged<AXUIElement>.fromOpaque(UnsafeMutableRawPointer(bitPattern: rawInt)!).takeRetainedValue()
            AXWindow.setFrame(w, target)
        }
    }

    // Global monitors fire on the main thread, so the AppKit work is safe here.
    private func showPreview(_ rect: CGRect) {
        MainActor.assumeIsolated {
            if preview == nil {
                let w = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
                w.isOpaque = false
                w.backgroundColor = .clear
                w.ignoresMouseEvents = true
                w.level = .floating
                w.hasShadow = false
                if let layer = w.contentView?.layer ?? { w.contentView?.wantsLayer = true; return w.contentView?.layer }() {
                    layer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.20).cgColor
                    layer.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
                    layer.borderWidth = 2
                    layer.cornerRadius = 10
                    layer.cornerCurve = .continuous   // matches macOS's rounded corners
                    layer.masksToBounds = true
                }
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
