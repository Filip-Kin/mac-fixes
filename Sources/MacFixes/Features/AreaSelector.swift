import AppKit

/// A full-screen overlay to drag-select a rectangle. Returns the selection in
/// global top-left (AX) coordinates, or nil if cancelled with Escape.
final class AreaSelector: @unchecked Sendable {
    private var window: NSWindow?
    private var completion: ((CGRect?) -> Void)?

    // Always invoked on the main run loop (hotkey callback / menu action).
    func select(_ completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
        MainActor.assumeIsolated {
            let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }

            let window = NSWindow(contentRect: union, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.backgroundColor = .clear
            window.isOpaque = false
            window.ignoresMouseEvents = false

            let view = SelectionView(frame: CGRect(origin: .zero, size: union.size))
            view.onFinish = { [weak self] rectInView in self?.finish(rectInView, windowOrigin: union.origin) }
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            window.makeFirstResponder(view)
            self.window = window
        }
    }

    private func finish(_ rectInView: CGRect?, windowOrigin: CGPoint) {
        MainActor.assumeIsolated { window?.orderOut(nil); window = nil }
        guard let r = rectInView, r.width > 4, r.height > 4 else { completion?(nil); completion = nil; return }

        // View coords (bottom-left, window-relative) -> global bottom-left -> top-left.
        let globalBL = CGRect(x: r.minX + windowOrigin.x, y: r.minY + windowOrigin.y,
                              width: r.width, height: r.height)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let topLeft = CGRect(x: globalBL.minX, y: primaryHeight - globalBL.maxY,
                             width: globalBL.width, height: globalBL.height)
        completion?(topLeft)
        completion = nil
    }
}

private final class SelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    private var start: CGPoint?
    private var current: CGPoint?

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        onFinish?(selectionRect)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) }   // Escape
    }

    private var selectionRect: CGRect? {
        guard let s = start, let c = current else { return nil }
        return CGRect(x: min(s.x, c.x), y: min(s.y, c.y),
                      width: abs(s.x - c.x), height: abs(s.y - c.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()
        guard let rect = selectionRect else { return }
        // Punch a clear hole for the selection.
        NSColor.clear.setFill()
        rect.fill(using: .copy)
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
