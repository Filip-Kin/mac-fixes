import AppKit
import ApplicationServices

/// Accessibility helpers for moving and resizing windows.
///
/// The AX coordinate space has its origin at the top-left of the primary
/// display with Y increasing downward, while NSScreen uses a bottom-left
/// origin — so screen frames are flipped before use.
enum AXWindow {

    /// True when keyboard focus is in a text-editing control (so Home/End should
    /// move within the line rather than scroll the page).
    static func focusedIsTextInput() -> Bool {
        let sys = AXUIElementCreateSystemWide()
        var elRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &elRef) == .success,
              let elVal = elRef, CFGetTypeID(elVal) == AXUIElementGetTypeID() else { return false }
        let el = elVal as! AXUIElement
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
        switch roleRef as? String {
        case kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole:
            return true
        default:
            return false
        }
    }

    static func focusedWindow() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var appRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &appRef) == .success,
              let appElement = appRef, CFGetTypeID(appElement) == AXUIElementGetTypeID()
        else { return nil }
        let app = appElement as! AXUIElement

        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let winElement = winRef, CFGetTypeID(winElement) == AXUIElementGetTypeID()
        else { return nil }
        return (winElement as! AXUIElement)
    }

    /// The frontmost app's focused window. More reliable than the system-wide
    /// focused-application query during a drag (which can return nil).
    static func frontmostWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var winRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
           let win = winRef, CFGetTypeID(win) == AXUIElementGetTypeID() {
            return (win as! AXUIElement)
        }
        var winsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &winsRef) == .success,
           let arr = winsRef as? [AXUIElement], let first = arr.first {
            return first
        }
        return nil
    }

    /// Find the on-screen window whose frame matches `target` (for resolving a
    /// CGWindowList frame back to an AX element to resize).
    static func window(matchingFrame target: CGRect, tolerance: CGFloat = 10) -> AXUIElement? {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var winsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &winsRef) == .success,
                  let arr = winsRef as? [AXUIElement] else { continue }
            for w in arr {
                if let f = frame(of: w),
                   abs(f.minX - target.minX) < tolerance, abs(f.minY - target.minY) < tolerance,
                   abs(f.width - target.width) < tolerance, abs(f.height - target.height) < tolerance {
                    return w
                }
            }
        }
        return nil
    }

    /// An app's standard windows as (element, title), in AX front-to-back order.
    /// Skips sheets, popovers and other non-standard windows.
    static func windowList(pid: pid_t) -> [(element: AXUIElement, title: String)] {
        let app = AXUIElementCreateApplication(pid)
        var winsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let arr = winsRef as? [AXUIElement] else { return [] }
        var out: [(AXUIElement, String)] = []
        for w in arr {
            var subroleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &subroleRef)
            if let sub = subroleRef as? String, sub != (kAXStandardWindowSubrole as String) { continue }
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &titleRef)
            let raw = (titleRef as? String) ?? ""
            out.append((w, raw.isEmpty ? "Untitled" : raw))
        }
        return out
    }

    /// On-screen window ids and frames for an app, for matching AX windows to a
    /// CGWindowID (needed to screenshot them).
    static func onScreenWindowIDs(pid: pid_t) -> [(id: CGWindowID, frame: CGRect)] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [(CGWindowID, CGRect)] = []
        for w in info {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let n = w[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            out.append((n, rect))
        }
        return out
    }

    /// All normal on-screen windows, front-to-back, for the switcher.
    static func allWindows() -> [(id: CGWindowID, pid: pid_t, title: String, frame: CGRect)] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [(CGWindowID, pid_t, String, CGRect)] = []
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let n = w[kCGWindowNumber as String] as? CGWindowID,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= 80, rect.height >= 80 else { continue }
            if (w[kCGWindowOwnerName as String] as? String) == "Filip's Mac Fixes" { continue }
            out.append((n, pid, (w[kCGWindowName as String] as? String) ?? "", rect))
        }
        return out
    }

    /// The AX element for a window on a pid whose frame best matches `frame`.
    static func element(pid: pid_t, matchingFrame frame: CGRect) -> AXUIElement? {
        var best: (el: AXUIElement, dist: CGFloat)?
        for e in windowList(pid: pid) {
            guard let f = AXWindow.frame(of: e.element) else { continue }
            let d = abs(f.minX - frame.minX) + abs(f.minY - frame.minY)
                + abs(f.width - frame.width) + abs(f.height - frame.height)
            if best == nil || d < best!.dist { best = (e.element, d) }
        }
        if let best, best.dist < 20 { return best.el }
        return nil
    }

    /// Bring one specific window to the front (and its app with it).
    static func raise(_ window: AXUIElement, pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        guard let pos = value(window, kAXPositionAttribute, .cgPoint, CGPoint.self),
              let size = value(window, kAXSizeAttribute, .cgSize, CGSize.self)
        else { return nil }
        return CGRect(origin: pos, size: size)
    }

    static func setFrame(_ window: AXUIElement, _ rect: CGRect) {
        var pos = rect.origin
        if let posValue = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        }
        var size = rect.size
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
        // Set position again — some apps clamp the first move against the old size.
        if let posValue = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        }
    }

    // MARK: Coordinate conversion

    private static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// A screen's full frame (including menu bar and Dock) in AX coordinates.
    static func axFullFrame(_ screen: NSScreen) -> CGRect {
        let f = screen.frame
        return CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
    }

    /// The screen containing the frontmost app's focused window, else main.
    static func focusedScreen() -> NSScreen {
        if let win = frontmostWindow(), let f = frame(of: win) { return screen(forAX: f) }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    /// A screen's usable area (minus menu bar and Dock) in AX coordinates.
    /// Also excludes the taskbar's reserved strip so snapped windows stop above
    /// it instead of sliding underneath.
    static func axVisibleFrame(_ screen: NSScreen) -> CGRect {
        let vf = screen.visibleFrame
        var rect = CGRect(x: vf.minX, y: primaryHeight - vf.maxY, width: vf.width, height: vf.height)
        if TaskbarLayout.reserves(screen) {
            rect.size.height = max(0, rect.size.height - TaskbarLayout.bottomInset)
        }
        return rect
    }

    /// Convert an AX (top-left origin) rect to NSScreen (bottom-left) coords.
    static func toBottomLeft(_ axRect: CGRect) -> CGRect {
        CGRect(x: axRect.minX, y: primaryHeight - axRect.maxY,
               width: axRect.width, height: axRect.height)
    }

    /// The screen containing an AX rect (by its centre); falls back to main.
    static func screen(forAX rect: CGRect) -> NSScreen {
        let centreBottomLeft = CGPoint(x: rect.midX, y: primaryHeight - rect.midY)
        return NSScreen.screens.first { $0.frame.contains(centreBottomLeft) }
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Frames (AX / top-left coords) of normal on-screen windows that intersect
    /// `vf`, for adaptive snapping. Excludes desktop items, our own windows, the
    /// window being dragged, and tiny/transparent windows.
    static func onScreenWindowFrames(excluding dragged: CGRect?, intersecting vf: CGRect) -> [CGRect] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var frames: [CGRect] = []
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0 else { continue }          // normal windows only
            if let a = w[kCGWindowAlpha as String] as? Double, a < 0.1 { continue }
            if (w[kCGWindowOwnerName as String] as? String) == "Filip's Mac Fixes" { continue }
            guard let bounds = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.intersects(vf), rect.width >= 100, rect.height >= 100
            else { continue }
            if let d = dragged, abs(rect.minX - d.minX) < 6, abs(rect.minY - d.minY) < 6,
               abs(rect.width - d.width) < 6, abs(rect.height - d.height) < 6 { continue }
            frames.append(rect)
        }
        return frames
    }

    // MARK: Generic attribute readers

    private static func value<T>(_ element: AXUIElement, _ attr: String,
                                 _ type: AXValueType, _ as: T.Type) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let out = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { out.deallocate() }
        if AXValueGetValue(value as! AXValue, type, out) { return out.pointee }
        return nil
    }
}
