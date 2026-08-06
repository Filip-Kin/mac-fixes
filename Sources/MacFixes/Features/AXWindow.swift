import AppKit
import ApplicationServices

/// Accessibility helpers for moving and resizing windows.
///
/// The AX coordinate space has its origin at the top-left of the primary
/// display with Y increasing downward, while NSScreen uses a bottom-left
/// origin — so screen frames are flipped before use.
enum AXWindow {

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

    /// A screen's usable area (minus menu bar and Dock) in AX coordinates.
    static func axVisibleFrame(_ screen: NSScreen) -> CGRect {
        let vf = screen.visibleFrame
        return CGRect(x: vf.minX, y: primaryHeight - vf.maxY, width: vf.width, height: vf.height)
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
