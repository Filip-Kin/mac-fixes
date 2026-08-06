import AppKit
import ApplicationServices

/// Focus-follows-mouse: after the cursor rests briefly over a window, make that
/// window active (and optionally raise it), so a click acts immediately instead
/// of being swallowed to activate the window first.
final class FocusFollows: @unchecked Sendable {
    private var monitor: Any?
    private var timer: Timer?

    var raise = true
    var delay: TimeInterval = 0.2

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.schedule()
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        timer?.invalidate(); timer = nil
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.focusUnderCursor()
        }
    }

    private func focusUnderCursor() {
        let loc = NSEvent.mouseLocation                       // bottom-left
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let ax = CGPoint(x: loc.x, y: primaryHeight - loc.y)  // top-left for AX

        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(ax.x), Float(ax.y), &element) == .success,
              let element, let window = windowAncestor(element) else { return }

        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success, pid > 0,
              pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid) else { return }

        if !app.isActive { app.activate() }
        if raise { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    private func windowAncestor(_ element: AXUIElement) -> AXUIElement? {
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           (roleRef as? String) == (kAXWindowRole as String) {
            return element
        }
        var winRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &winRef) == .success,
           let win = winRef, CFGetTypeID(win) == AXUIElementGetTypeID() {
            return (win as! AXUIElement)
        }
        return nil
    }
}
