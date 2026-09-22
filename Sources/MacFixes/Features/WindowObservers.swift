import AppKit
import ApplicationServices

/// Close-quits: when a regular app's last window closes, quit it (Windows-like).
///
/// Implemented by polling each app's window count rather than AX destroy
/// notifications, which many apps (TextEdit and other document apps) never emit.
///
/// Guarded heavily against false positives: an app's AX window list can briefly
/// read empty during Space switches, fullscreen transitions (including apps like
/// Teams that fake fullscreen), app launches and heavy load. Quitting on a single
/// transient-zero reading would wrongly kill unrelated apps, so we require the
/// count to stay at zero for several consecutive seconds, skip hidden apps, pause
/// around Space changes, and re-check immediately before terminating.
final class WindowObservers: @unchecked Sendable {
    fileprivate var closeQuits = false
    private var timer: Timer?
    private var hadWindows: [pid_t: Bool] = [:]     // has this app shown ≥1 window while observed
    private var zeroStreak: [pid_t: Int] = [:]      // consecutive polls reading zero windows
    private var pauseUntil = Date.distantPast
    private var spaceObserver: NSObjectProtocol?
    private let zeroThreshold = 3                    // ~3 s of no windows before quitting

    func configure(closeQuits: Bool) {
        self.closeQuits = closeQuits
        closeQuits ? start() : stop()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        hadWindows.removeAll()
        zeroStreak.removeAll()
        if let o = spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            spaceObserver = nil
        }
    }

    private func start() {
        guard timer == nil else { return }
        reseed()   // seed baselines so apps that already have no windows aren't quit
        // A Space switch — including an app entering (or faking) fullscreen — can
        // make other apps' AX window lists momentarily read empty. Pause quitting
        // for a few seconds around it and re-baseline.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.pauseUntil = Date().addingTimeInterval(3)
            self.reseed()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        guard closeQuits, Date() >= pauseUntil else { return }
        let selfPid = ProcessInfo.processInfo.processIdentifier
        for app in regularApps() {
            let pid = app.processIdentifier
            if pid == selfPid || app.bundleIdentifier == "com.apple.finder" { continue }

            let count = windowCount(pid)
            if count < 0 { zeroStreak[pid] = 0; continue }        // AX read failed — leave it alone
            if count > 0 { hadWindows[pid] = true; zeroStreak[pid] = 0; continue }

            // count == 0. Only a candidate if it previously had windows and is not
            // merely hidden (a hidden app still owns its windows).
            guard hadWindows[pid] == true, !app.isHidden else { zeroStreak[pid] = 0; continue }
            zeroStreak[pid, default: 0] += 1
            if zeroStreak[pid, default: 0] >= zeroThreshold {
                // Final immediate re-check to dodge a lingering transient.
                if windowCount(pid) == 0, !app.isHidden {
                    app.terminate()
                    hadWindows[pid] = false
                }
                zeroStreak[pid] = 0
            }
        }
        // Forget apps that have quit.
        hadWindows = hadWindows.filter { NSRunningApplication(processIdentifier: $0.key) != nil }
        zeroStreak = zeroStreak.filter { NSRunningApplication(processIdentifier: $0.key) != nil }
    }

    /// Re-establish the baseline: any app that currently has windows is remembered
    /// as having had them, and streaks are cleared.
    private func reseed() {
        for app in regularApps() {
            let pid = app.processIdentifier
            if windowCount(pid) > 0 { hadWindows[pid] = true }
            zeroStreak[pid] = 0
        }
    }

    private func regularApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
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
