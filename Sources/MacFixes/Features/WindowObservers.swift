import AppKit
import ApplicationServices

/// Watches windows across apps via the Accessibility API for close-quits: when
/// an app's last window closes, quit the app (Windows-like).
final class WindowObservers: @unchecked Sendable {
    fileprivate var closeQuits = false

    private var appObservers: [pid_t: AXObserver] = [:]
    private var observedWindows: [AXUIElement] = []   // retained so notifications stay live
    private var launchObs: NSObjectProtocol?
    private var terminateObs: NSObjectProtocol?

    func configure(closeQuits: Bool) {
        self.closeQuits = closeQuits
        closeQuits ? startAll() : stop()
    }

    func stop() {
        for (pid, _) in appObservers { detach(pid) }
        appObservers.removeAll()
        observedWindows.removeAll()
        let nc = NSWorkspace.shared.notificationCenter
        if let o = launchObs { nc.removeObserver(o); launchObs = nil }
        if let o = terminateObs { nc.removeObserver(o); terminateObs = nil }
    }

    // MARK: Attach / detach

    private func startAll() {
        let ws = NSWorkspace.shared
        for app in ws.runningApplications where app.activationPolicy == .regular {
            attach(app.processIdentifier)
        }
        guard launchObs == nil else { return }
        launchObs = ws.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.attach(app.processIdentifier)
            }
        }
        terminateObs = ws.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.detach(app.processIdentifier)
            }
        }
    }

    private func attach(_ pid: pid_t) {
        guard appObservers[pid] == nil, pid > 0 else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &observer) == .success, let observer else { return }

        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, app, kAXWindowCreatedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        appObservers[pid] = observer

        // Observe windows that already exist.
        var wins: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &wins) == .success,
           let arr = wins as? [AXUIElement] {
            arr.forEach { observeWindow($0, observer) }
        }
    }

    private func detach(_ pid: pid_t) {
        guard let observer = appObservers[pid] else { return }
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        appObservers[pid] = nil
    }

    fileprivate func observeWindow(_ window: AXUIElement, _ observer: AXObserver) {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, refcon)
        observedWindows.append(window)
    }

    // MARK: Notification handling

    fileprivate func handle(observer: AXObserver, element: AXUIElement, notification: String) {
        switch notification {
        case kAXWindowCreatedNotification:
            observeWindow(element, observer)
        case kAXUIElementDestroyedNotification:
            windowDestroyed(element)
        default:
            break
        }
    }

    private func windowDestroyed(_ window: AXUIElement) {
        guard closeQuits else { return }
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success, pid > 0 else { return }
        let app = AXUIElementCreateApplication(pid)
        var wins: CFTypeRef?
        let ok = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &wins) == .success
        let count = ok ? ((wins as? [AXUIElement])?.count ?? 0) : 0
        if count == 0 {
            NSRunningApplication(processIdentifier: pid)?.terminate()
        }
    }
}

/// C callback trampoline into the WindowObservers instance carried in refcon.
private func axObserverCallback(_ observer: AXObserver,
                                _ element: AXUIElement,
                                _ notification: CFString,
                                _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let me = Unmanaged<WindowObservers>.fromOpaque(refcon).takeUnretainedValue()
    me.handle(observer: observer, element: element, notification: notification as String)
}
