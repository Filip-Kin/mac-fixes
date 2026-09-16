import AppKit
import ApplicationServices

/// Close-quits: when a regular app's last window closes, quit it (Windows-like).
///
/// Implemented by polling each app's window count rather than AX destroy
/// notifications, which many apps (TextEdit and other document apps) never emit.
/// When an app that had at least one window drops to zero, it is terminated.
final class WindowObservers: @unchecked Sendable {
    fileprivate var closeQuits = false
    private var timer: Timer?
    private var lastCounts: [pid_t: Int] = [:]

    func configure(closeQuits: Bool) {
        self.closeQuits = closeQuits
        closeQuits ? start() : stop()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastCounts.removeAll()
    }

    private func start() {
        guard timer == nil else { return }
        // Seed with current counts so apps that already have no windows aren't quit.
        lastCounts = currentCounts()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        guard closeQuits else { return }
        let selfPid = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let pid = app.processIdentifier
            if pid == selfPid || app.bundleIdentifier == "com.apple.finder" { continue }

            let count = windowCount(pid)
            if count < 0 { continue }          // AX couldn't read; leave it alone
            let prev = lastCounts[pid]
            lastCounts[pid] = count
            if let prev, prev >= 1, count == 0 {
                app.terminate()                // last window just closed
            }
        }
        // Forget apps that have quit.
        lastCounts = lastCounts.filter { NSRunningApplication(processIdentifier: $0.key) != nil }
    }

    private func currentCounts() -> [pid_t: Int] {
        var counts: [pid_t: Int] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let c = windowCount(app.processIdentifier)
            if c >= 0 { counts[app.processIdentifier] = c }
        }
        return counts
    }

    /// Number of standard windows, or -1 if the Accessibility read failed.
    private func windowCount(_ pid: pid_t) -> Int {
        let app = AXUIElementCreateApplication(pid)
        var wins: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &wins) == .success,
              let arr = wins as? [AXUIElement] else { return -1 }
        return arr.count
    }
}
