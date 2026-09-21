import AppKit
import ApplicationServices

/// A full-screen overlay to drag-select a rectangle, with ShareX-style snapping:
/// while hovering (before any drag) the window — or the pane/control within it —
/// under the cursor is highlighted, and a plain click captures that region.
/// Dragging does a freeform selection.
///
/// Two modes:
///  - `select`: returns the selection rect in global top-left (AX) coordinates,
///    for capturing the live screen (used by area recording).
///  - `selectFrozen`: shows a frozen snapshot of each screen as the backdrop and
///    returns the cropped image, so a screenshot captures the moment the tool was
///    triggered rather than whatever is on screen when the selection is released.
final class AreaSelector: @unchecked Sendable {
    private var windows: [NSWindow] = []
    private var rectCompletion: ((CGRect?) -> Void)?
    private var imageCompletion: ((CGImage?) -> Void)?
    private var escMonitor: Any?
    private var done = false

    // MARK: Live rect (recording)

    func select(_ completion: @escaping (CGRect?) -> Void) {
        rectCompletion = completion
        done = false
        MainActor.assumeIsolated {
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            for screen in NSScreen.screens {
                let (window, view) = makeOverlay(for: screen, primaryHeight: primaryHeight, background: nil)
                view.onFinish = { [weak self] r in self?.finishRect(r, windowOrigin: screen.frame.origin) }
                windows.append(window)
            }
            activateAndArmEscape()
        }
    }

    // MARK: Frozen snapshot (screenshot)

    func selectFrozen(images: [CGDirectDisplayID: CGImage], _ completion: @escaping (CGImage?) -> Void) {
        imageCompletion = completion
        done = false
        MainActor.assumeIsolated {
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            for screen in NSScreen.screens {
                let img = images[screen.displayID]
                let scale = screen.backingScaleFactor
                let frame = screen.frame
                let (window, view) = makeOverlay(for: screen, primaryHeight: primaryHeight, background: img)
                view.onFinish = { [weak self] r in
                    self?.finishFrozen(r, image: img, screenSize: frame.size, scale: scale)
                }
                windows.append(window)
            }
            activateAndArmEscape()
        }
    }

    // MARK: Overlay construction

    @MainActor
    private func makeOverlay(for screen: NSScreen, primaryHeight: CGFloat,
                             background: CGImage?) -> (NSWindow, SelectionView) {
        let frame = screen.frame
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let container = NSView(frame: CGRect(origin: .zero, size: frame.size))
        // Frozen backdrop (screenshot mode): the selection's transparent hole
        // then reveals this snapshot rather than the live screen.
        if let background {
            let iv = NSImageView(frame: container.bounds)
            iv.image = NSImage(cgImage: background, size: frame.size)
            iv.imageScaling = .scaleAxesIndependently
            iv.autoresizingMask = [.width, .height]
            container.addSubview(iv)
        }
        let view = SelectionView(frame: CGRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]
        view.windowOrigin = frame.origin
        view.primaryHeight = primaryHeight
        container.addSubview(view)

        window.contentView = container
        window.orderFrontRegardless()
        window.makeFirstResponder(view)
        return (window, view)
    }

    @MainActor
    private func activateAndArmEscape() {
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.crosshair.set()
        let cursor = NSEvent.mouseLocation
        (windows.first { $0.frame.contains(cursor) } ?? windows.first)?.makeKey()
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.cancelAll(); return nil }
            return e
        }
    }

    /// Tear down every overlay once. Returns false if it was already done.
    private func dismiss() -> Bool {
        var already = false
        MainActor.assumeIsolated {
            if done { already = true; return }
            done = true
            if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
            for w in windows { w.orderOut(nil) }
            windows = []
        }
        return !already
    }

    private func cancelAll() {
        guard dismiss() else { return }
        rectCompletion?(nil); rectCompletion = nil
        imageCompletion?(nil); imageCompletion = nil
    }

    // MARK: Completions

    private func finishRect(_ rectInView: CGRect?, windowOrigin: CGPoint) {
        guard dismiss() else { return }
        guard let r = rectInView, r.width > 4, r.height > 4 else { rectCompletion?(nil); rectCompletion = nil; return }
        // View coords (bottom-left, window-relative) -> global bottom-left -> top-left.
        let globalBL = CGRect(x: r.minX + windowOrigin.x, y: r.minY + windowOrigin.y,
                              width: r.width, height: r.height)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let topLeft = CGRect(x: globalBL.minX, y: primaryHeight - globalBL.maxY,
                             width: globalBL.width, height: globalBL.height)
        rectCompletion?(topLeft)
        rectCompletion = nil
    }

    private func finishFrozen(_ rectInView: CGRect?, image: CGImage?, screenSize: CGSize, scale: CGFloat) {
        guard dismiss() else { return }
        guard let r = rectInView, r.width > 4, r.height > 4, let image else {
            imageCompletion?(nil); imageCompletion = nil; return
        }
        // View points (bottom-left) -> image pixels (top-left origin).
        var px = CGRect(x: r.minX * scale, y: (screenSize.height - r.maxY) * scale,
                        width: r.width * scale, height: r.height * scale)
        px = px.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        imageCompletion?(px.isNull || px.width < 1 ? nil : image.cropping(to: px))
        imageCompletion = nil
    }
}

private final class SelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    var windowOrigin: CGPoint = .zero
    var primaryHeight: CGFloat = 0

    private var start: CGPoint?           // mouse-down point (view coords)
    private var current: CGPoint?         // latest drag point (view coords)
    private var dragging = false
    private var snapRect: CGRect?         // snap highlight in view coords

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeAlways, .mouseMoved, .cursorUpdate, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { NSCursor.crosshair.set() }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()             // keep the crosshair even over panes
        guard start == nil else { return }   // not while pressing/dragging
        updateSnap()
    }

    private func updateSnap() {
        let global = NSEvent.mouseLocation   // global, bottom-left origin
        if let ax = SnapTarget.rect(atGlobalBottomLeft: global, primaryHeight: primaryHeight) {
            // AX (top-left) -> global bottom-left -> view (window-relative).
            let glBLy = primaryHeight - ax.maxY
            snapRect = CGRect(x: ax.minX - windowOrigin.x, y: glBLy - windowOrigin.y,
                              width: ax.width, height: ax.height)
        } else {
            snapRect = nil
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        dragging = false
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        if let s = start, let c = current, hypot(c.x - s.x, c.y - s.y) > 3 {
            dragging = true          // a real drag: freeform selection, ignore snap
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        defer { start = nil; current = nil; dragging = false }
        if dragging, let r = dragRect, r.width > 4, r.height > 4 {
            onFinish?(r)
        } else if let snap = snapRect {   // plain click on a snapped region
            onFinish?(snap)
        }
        // else: empty click on nothing — keep the overlay open.
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) }   // Escape
    }

    private var dragRect: CGRect? {
        guard let s = start, let c = current else { return nil }
        return CGRect(x: min(s.x, c.x), y: min(s.y, c.y),
                      width: abs(s.x - c.x), height: abs(s.y - c.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()

        let rect = dragging ? dragRect : snapRect
        guard let rect else { return }

        // Punch a clear hole for the region (reveals the frozen backdrop, or the
        // live screen when there is none).
        NSColor.clear.setFill()
        rect.fill(using: .copy)
        // A faint accent wash marks a snapped (click-to-grab) region.
        if !dragging {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            rect.fill()
        }
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.stroke()

        let label = "\(Int(rect.width)) × \(Int(rect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        ]
        label.draw(at: CGPoint(x: rect.minX + 4, y: rect.maxY + 4), withAttributes: attrs)
    }
}

/// Finds the region to snap to under a point: the window under the cursor, or
/// the deepest Accessibility element (pane/control) within it. Returned in AX
/// top-left global coordinates. Window detection needs no special permission;
/// pane detection needs Accessibility (falls back to the whole window without).
enum SnapTarget {
    static func rect(atGlobalBottomLeft p: CGPoint, primaryHeight: CGFloat) -> CGRect? {
        let axPoint = CGPoint(x: p.x, y: primaryHeight - p.y)   // top-left origin
        guard let (pid, windowFrame) = windowUnder(axPoint) else { return nil }

        // Hit-test the app's own tree, which ignores our overlay's z-order.
        let appEl = AXUIElementCreateApplication(pid)
        var elRef: AXUIElement?
        if AXUIElementCopyElementAtPosition(appEl, Float(axPoint.x), Float(axPoint.y), &elRef) == .success,
           let el = elRef, let f = AXWindow.frame(of: el), f.width >= 8, f.height >= 8 {
            let clipped = f.intersection(windowFrame)
            return clipped.isNull ? windowFrame : clipped
        }
        return windowFrame
    }

    /// The frontmost normal window (not ours) whose bounds contain the point,
    /// with its owning pid. Bounds are already AX top-left global coordinates.
    private static func windowUnder(_ axPoint: CGPoint) -> (pid: pid_t, frame: CGRect)? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in info {   // front-to-back
            guard (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
            if (w[kCGWindowOwnerName as String] as? String) == "Filip's Mac Fixes" { continue }
            if let a = w[kCGWindowAlpha as String] as? Double, a < 0.1 { continue }
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.contains(axPoint) else { continue }
            return (pid, rect)
        }
        return nil
    }
}
