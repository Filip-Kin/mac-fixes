import AppKit
import ApplicationServices

/// Private HIServices call that returns an AX window element's CGWindowID —
/// the only reliable way to tell apart same-size stacked windows of one app.
/// Carbon's pid -> ProcessSerialNumber (unavailable in Swift's headers, still exported).
@_silgen_name("GetProcessForPID")
private func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

/// Builds an AX element from a pid + element id, which reaches windows on other
/// Spaces that the normal windows list leaves out.
@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func _AXUIElementCreateWithRemoteToken(_ data: CFData) -> Unmanaged<AXUIElement>?

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

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
        // Called from the keyboard tap, which every key press waits on. A busy
        // app can take seconds to answer (the default timeout is 6 s); give up
        // fast and treat it as "not a text field" so Home/End pass through.
        AXUIElementSetMessagingTimeout(sys, 0.1)
        var elRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &elRef) == .success,
              let elVal = elRef, CFGetTypeID(elVal) == AXUIElementGetTypeID() else { return false }
        let el = elVal as! AXUIElement
        AXUIElementSetMessagingTimeout(el, 0.1)
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
    static func windowList(pid: pid_t, timeout: Float? = nil) -> [(element: AXUIElement, title: String)] {
        let app = AXUIElementCreateApplication(pid)
        if let timeout { AXUIElementSetMessagingTimeout(app, timeout) }
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

    /// An app's standard windows in a stable order: oldest first (by CGWindowID,
    /// which the window server hands out in increasing order). The raw AX list
    /// is front-to-back, so it reshuffles on every focus change. Also returns
    /// the index of the app's focused window, if it is one of them.
    static func orderedWindows(pid: pid_t) -> (windows: [(element: AXUIElement, title: String, id: CGWindowID)], focused: Int?) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)   // a hung app must not stall the taskbar
        let wins = windowList(pid: pid, timeout: 0.3).map { e -> (element: AXUIElement, title: String, id: CGWindowID) in
            var wid: CGWindowID = 0
            _ = _AXUIElementGetWindow(e.element, &wid)
            return (e.element, e.title, wid)
        }
        // Unknown ids (0) go last, keeping their AX order.
        let ordered = wins.enumerated().sorted { a, b in
            let ka = a.element.id == 0 ? CGWindowID.max : a.element.id
            let kb = b.element.id == 0 ? CGWindowID.max : b.element.id
            return ka != kb ? ka < kb : a.offset < b.offset
        }.map(\.element)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
              let f = focusedRef, CFGetTypeID(f) == AXUIElementGetTypeID() else { return (ordered, nil) }
        let focusedEl = f as! AXUIElement
        return (ordered, ordered.firstIndex { CFEqual($0.element, focusedEl) })
    }

    /// A window element's CGWindowID, or 0 if unknown.
    static func windowID(of window: AXUIElement) -> CGWindowID {
        var wid: CGWindowID = 0
        return _AXUIElementGetWindow(window, &wid) == .success ? wid : 0
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

    /// All normal windows, front-to-back, for the switcher. On-screen ones
    /// only by default; `onScreenOnly: false` also returns windows on other
    /// Spaces (and minimized or hidden ones), which the caller must filter.
    static func allWindows(onScreenOnly: Bool = true) -> [(id: CGWindowID, pid: pid_t, title: String, frame: CGRect)] {
        let opts: CGWindowListOption = onScreenOnly
            ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll, .excludeDesktopElements]
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

    /// An app's AX window elements keyed by their exact CGWindowID, so stacked
    /// same-size windows map to distinct elements.
    static func axWindowsByID(pid: pid_t) -> [CGWindowID: AXUIElement] {
        var out: [CGWindowID: AXUIElement] = [:]
        for e in windowList(pid: pid) {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(e.element, &wid) == .success, wid != 0 {
                out[wid] = e.element
            }
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

    // MARK: Windows on other Spaces

    /// The AX element of one window by id, found by trying element ids 0..<1000
    /// for the process (about 20 ms). Works for windows on other Spaces.
    static func elementByRemoteToken(pid: pid_t, windowID: CGWindowID) -> AXUIElement? {
        var token = Data(count: 20)
        var p = pid, zero: Int32 = 0, magic: Int32 = 0x636f636f
        token.replaceSubrange(0..<4, with: Data(bytes: &p, count: 4))
        token.replaceSubrange(4..<8, with: Data(bytes: &zero, count: 4))
        token.replaceSubrange(8..<12, with: Data(bytes: &magic, count: 4))
        for i in 0..<1000 {
            var id = UInt64(i)
            token.replaceSubrange(12..<20, with: Data(bytes: &id, count: 8))
            guard let el = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(el, 0.05)
            var w: CGWindowID = 0
            if _AXUIElementGetWindow(el, &w) == .success, w == windowID { return el }
        }
        return nil
    }

    /// Windows sitting on other Spaces that the accessibility windows list does
    /// not show (e.g. the desktop's windows while a display is in native
    /// fullscreen), grouped by owner pid, front-to-back. Titled, reasonably
    /// sized windows that belong to a Space; hidden tab windows and helpers
    /// are left out. Callers drop the ids their AX list already has.
    static func otherSpaceWindows() -> [pid_t: [(id: CGWindowID, title: String)]] {
        guard let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [:] }
        var out: [pid_t: [(CGWindowID, String)]] = [:]
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowIsOnscreen as String] as? Bool) != true,
                  let n = w[kCGWindowNumber as String] as? CGWindowID,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let title = w[kCGWindowName as String] as? String, !title.isEmpty,
                  let bounds = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= 200, rect.height >= 120,
                  isOnSomeSpace(n) else { continue }
            out[pid, default: []].append((n, title))
        }
        return out
    }

    /// True if the window lives on some Space. Hidden tab windows, helper
    /// windows and minimized-to-nowhere ones belong to none.
    static func isOnSomeSpace(_ wid: CGWindowID) -> Bool {
        typealias MainConn = @convention(c) () -> Int32
        typealias SpacesFor = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
        guard let h = dlopen(nil, RTLD_NOW),
              let c = dlsym(h, "CGSMainConnectionID"), let f = dlsym(h, "CGSCopySpacesForWindows") else { return false }
        let conn = unsafeBitCast(c, to: MainConn.self)()
        let spaces = unsafeBitCast(f, to: SpacesFor.self)(conn, 0x7, [NSNumber(value: wid)] as CFArray)?.takeRetainedValue()
        return ((spaces as? [Any])?.isEmpty == false)
    }

    /// True if the window sits in a native fullscreen Space (Space type 4).
    static func isInFullscreenSpace(_ wid: CGWindowID) -> Bool {
        typealias MainConn = @convention(c) () -> Int32
        typealias SpacesFor = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
        typealias SpaceType = @convention(c) (Int32, UInt64) -> Int32
        guard let h = dlopen(nil, RTLD_NOW),
              let c = dlsym(h, "CGSMainConnectionID"), let f = dlsym(h, "CGSCopySpacesForWindows"),
              let t = dlsym(h, "SLSSpaceGetType") else { return false }
        let conn = unsafeBitCast(c, to: MainConn.self)()
        let spaces = unsafeBitCast(f, to: SpacesFor.self)(conn, 0x7, [NSNumber(value: wid)] as CFArray)?.takeRetainedValue()
        let type = unsafeBitCast(t, to: SpaceType.self)
        return (spaces as? [NSNumber] ?? []).contains { type(conn, $0.uint64Value) == 4 }
    }

    /// Brings one specific window forward even if it sits on another Space
    /// (WindowServer switches to that Space), for windows the accessibility
    /// API cannot see from here. Falls back to plain app activation.
    @MainActor
    static func focusAcrossSpaces(windowID: CGWindowID, pid: pid_t) {
        NotificationCenter.default.post(name: .windowRaised, object: nil,
                                        userInfo: ["pid": pid, "windowID": windowID])
        // A window in its own fullscreen Space: activating the app and raising
        // the window is what the taskbar does and is enough. Fronting the
        // process on the window id and clearing "minimized" were not.
        if isInFullscreenSpace(windowID) {
            trace("AltTab", "focusAcrossSpaces wid=\(windowID) pid=\(pid) fullscreen space: activate + raise")
            NSRunningApplication(processIdentifier: pid)?.activate(options: [])
            func raiseOnly() {
                guard let el = elementByRemoteToken(pid: pid, windowID: windowID) ?? axWindowsByID(pid: pid)[windowID] else { return }
                AXUIElementPerformAction(el, kAXRaiseAction as CFString)
            }
            raiseOnly()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { raiseOnly() }
            return
        }
        typealias SetFront = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
        typealias PostEvent = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
        var psn = ProcessSerialNumber()
        let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
        if GetProcessForPID(pid, &psn) == 0, let h = skylight, let f = dlsym(h, "_SLPSSetFrontProcessWithOptions") {
            // Front the process on this specific window; WindowServer switches
            // to the window's Space.
            let rc = unsafeBitCast(f, to: SetFront.self)(&psn, windowID, 0x200 /* user generated */)
            trace("AltTab", "focusAcrossSpaces wid=\(windowID) pid=\(pid) setFront rc=\(rc)")
            // Then make that window key, the way the system does on a click.
            if let p = dlsym(h, "SLPSPostEventRecordTo") {
                var bytes = [UInt8](repeating: 0, count: 0xf8)
                bytes[0x04] = 0xf8; bytes[0x3a] = 0x10
                var wid = windowID
                memcpy(&bytes[0x3c], &wid, MemoryLayout<UInt32>.size)
                memset(&bytes[0x20], 0xff, 0x10)
                let post = unsafeBitCast(p, to: PostEvent.self)
                bytes[0x08] = 0x01; _ = post(&psn, &bytes)
                bytes[0x08] = 0x02; _ = post(&psn, &bytes)
            }
        } else {
            trace("AltTab", "focusAcrossSpaces: no process serial number for pid=\(pid)")
        }
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        // Raising the exact window's AX element is what makes macOS switch to
        // its Space; the plain windows list cannot see it from here, so build
        // the element directly. Again shortly after, once the Space has moved.
        func raise() {
            guard let el = elementByRemoteToken(pid: pid, windowID: windowID) ?? axWindowsByID(pid: pid)[windowID] else {
                trace("AltTab", "focusAcrossSpaces: no AX element for wid=\(windowID)")
                return
            }
            AXUIElementSetAttributeValue(el, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(el, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        raise()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { raise() }
    }

    /// Brings the app forward and opens a new window: its real "New Window"
    /// menu item, or Cmd+N when it has none (Cmd+N is "new file" in some apps,
    /// so the menu item comes first).
    @MainActor
    static func openNewWindow(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate(options: [])
        if pressMenuItem(pid: pid, titled: ["New Window", "New window"]) { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let src = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0x2D /* N */, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 0x2D, keyDown: false)
            down?.flags = .maskCommand; up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
        }
    }

    /// Press the app's menu item with one of these exact titles (e.g. "New
    /// Window"), so it works regardless of the app's shortcut. Returns false if
    /// no such item exists.
    @discardableResult
    static func pressMenuItem(pid: pid_t, titled titles: [String]) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var barRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &barRef) == .success,
              let bar = barRef, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return false }
        return pressInMenu(bar as! AXUIElement, titles: Set(titles), depth: 0)
    }

    private static func pressInMenu(_ element: AXUIElement, titles: Set<String>, depth: Int) -> Bool {
        guard depth < 6 else { return false }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return false }
        for child in children {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef)
            if let title = titleRef as? String, titles.contains(title),
               AXUIElementPerformAction(child, kAXPressAction as CFString) == .success {
                return true
            }
            if pressInMenu(child, titles: titles, depth: depth + 1) { return true }
        }
        return false
    }

    /// Bring one specific window to the front (and its app with it).
    static func raise(_ window: AXUIElement, pid: pid_t) {
        // Tell the taskbar first, so its focus dash moves before the app
        // has even finished activating.
        NotificationCenter.default.post(name: .windowRaised, object: nil,
                                        userInfo: ["pid": pid, "windowID": windowID(of: window)])
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
