import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Close-quits: when you close an app's last window, quit it (Windows-like).
///
/// Driven by the close gesture, not by watching window counts. Earlier versions
/// polled every app and quit any whose window list read empty for a few
/// seconds. That list also reads empty during fullscreen on another Space, Space
/// switches, Teams-style fake fullscreen and heavy load, so apps the user was
/// not touching (VS Code, Teams) got quit and lost work. Patching each case
/// left the next one open.
///
/// Now an app can only be quit in the couple of seconds after the user closes
/// one of *its* windows: a click on a window's red close button, or ⌘W while
/// it is frontmost. Only then do we check that no windows remain, both in the
/// Accessibility list and in the window server's list across all Spaces. No
/// close gesture, no quit, whatever the window lists say.
final class WindowObservers: @unchecked Sendable {
    fileprivate var closeQuits = false
    private var monitors: [Any] = []
    private var closeObserver: NSObjectProtocol?

    /// Apps whose window the user just closed, and until when we watch them.
    private var armed: [pid_t: Date] = [:]
    private var timer: Timer?
    private let armFor: TimeInterval = 2.0

    func configure(closeQuits: Bool) {
        self.closeQuits = closeQuits
        closeQuits ? start() : stop()
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        if let o = closeObserver { NotificationCenter.default.removeObserver(o); closeObserver = nil }
        timer?.invalidate()
        timer = nil
        armed.removeAll()
    }

    private func start() {
        guard monitors.isEmpty else { return }
        // Global monitors only see other apps' events, which is what we want.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            self?.mouseDown(at: NSEvent.mouseLocation)
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            self?.keyDown(e)
        }) { monitors.append(m) }
        // Closes done by Mac Fixes itself (the taskbar popup's ✕).
        closeObserver = NotificationCenter.default.addObserver(forName: .userClosedWindow, object: nil, queue: .main) { [weak self] note in
            if let pid = note.userInfo?["pid"] as? pid_t { self?.arm(pid) }
        }
    }

    // MARK: Close gestures

    private func mouseDown(at cocoaPoint: NSPoint) {
        // AX uses top-left-origin screen coordinates.
        guard let primary = NSScreen.screens.first else { return }
        let x = Float(cocoaPoint.x), y = Float(primary.frame.maxY - cocoaPoint.y)
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.2)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, x, y, &hit) == .success, let el = hit else {
            extendIfArmed(NSWorkspace.shared.frontmostApplication?.processIdentifier)
            return
        }
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        var sub: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &sub)
        if (sub as? String) == kAXCloseButtonSubrole {
            arm(pid)
        } else {
            // Clicking inside an app that is about to quit (e.g. "Don't Save"
            // in its save sheet) keeps the watch going.
            extendIfArmed(pid)
        }
    }

    private func keyDown(_ e: NSEvent) {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        if Int(e.keyCode) == kVK_ANSI_W, mods == .command || mods == [.command, .shift], let pid {
            arm(pid)
        } else {
            extendIfArmed(pid)   // e.g. Return on a save sheet
        }
    }

    private func arm(_ pid: pid_t) {
        guard closeQuits, eligible(pid) else { return }
        armed[pid] = Date().addingTimeInterval(armFor)
        startTimer()
    }

    private func extendIfArmed(_ pid: pid_t?) {
        guard let pid, armed[pid] != nil else { return }
        armed[pid] = Date().addingTimeInterval(armFor)
    }

    private func eligible(_ pid: pid_t) -> Bool {
        guard pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular,
              app.bundleIdentifier != "com.apple.finder" else { return false }
        return true
    }

    // MARK: After a close

    /// Polls only while something is armed; idle otherwise.
    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func check() {
        let now = Date()
        for (pid, until) in armed {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
                armed[pid] = nil; continue
            }
            if windowCount(pid) == 0, !app.isHidden, windowServerCount(pid) == 0 {
                trace("CloseQuits", "quitting \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?")): its last window was just closed")
                app.terminate()
                armed[pid] = nil
            } else if now > until {
                armed[pid] = nil   // a window remains: it was not the last one
            }
        }
        if armed.isEmpty { timer?.invalidate(); timer = nil }
    }

    /// Normal (layer 0), reasonably sized windows the window server knows for
    /// this app on any Space, on screen or not.
    private func windowServerCount(_ pid: pid_t) -> Int {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return 1   // cannot tell: treat as "has windows" and keep the app
        }
        return list.filter { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return (b["Width"] ?? 0) >= 100 && (b["Height"] ?? 0) >= 100
        }.count
    }

    /// Number of standard windows, or -1 if the Accessibility read failed.
    private func windowCount(_ pid: pid_t) -> Int {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var wins: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &wins) == .success,
              let arr = wins as? [AXUIElement] else { return -1 }
        return arr.count
    }
}
