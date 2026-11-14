import AppKit
import SwiftUI
import Carbon.HIToolbox
import UniformTypeIdentifiers
import ScreenCaptureKit

enum TaskbarMetrics {
    static let barHeight: CGFloat = 52
}

/// Space the taskbar reserves, read by `AXWindow.axVisibleFrame` so our window
/// snapping (maximize, halves, quarters, drag-snap) stops above the bar instead
/// of sliding under it. Only touched on the main actor.
enum TaskbarLayout {
    nonisolated(unsafe) static var bottomInset: CGFloat = 0
    nonisolated(unsafe) static var reservedDisplays: Set<CGDirectDisplayID> = []

    /// True if a taskbar is visible on this screen.
    static func reserves(_ screen: NSScreen) -> Bool {
        bottomInset > 0 && reservedDisplays.contains(screen.displayID)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// A Windows-style taskbar: a strip along the bottom of the screen showing the
/// apps you have pinned and the apps that are open, so you can see and switch
/// what is running at a glance without the Dock. Click an icon to switch (or
/// launch a pinned app that is closed); right-click for New Window / Pin / Quit;
/// hover an app with several windows to pick one; drag pinned icons to reorder.
///
/// Runs above normal windows as a non-activating panel, so clicking a taskbar
/// button never steals focus from the app you are switching to.
final class TaskbarFeature: Feature, @unchecked Sendable {
    // Touched only on the main actor (via assumeIsolated below).
    private var panels: [TaskbarPanel] = []
    private var peekPanel: PeekPanel?
    private var calendarPanel: CalendarPanel?
    private var calMonitor: Any?
    /// Displays a fullscreen window covers, and the subset whose bar is
    /// currently slid out because the pointer hit the bottom edge.
    private var fullscreenDisplays: Set<CGDirectDisplayID> = []
    private var revealedDisplays: Set<CGDirectDisplayID> = []
    private var edgeTimer: Timer?
    private let model = TaskbarModel()
    private var allScreens: Bool { UserDefaults.standard.bool(forKey: "taskbarAllScreens") }

    /// What the Start button does (wired to the Start menu by FeatureManager).
    @MainActor
    func setStartAction(_ action: @escaping () -> Void) {
        model.onStartButton = action
    }

    /// Opens the settings window (wired to the app delegate).
    @MainActor
    func setOpenSettingsAction(_ action: @escaping () -> Void) {
        model.onOpenSettings = action
    }

    @discardableResult
    func start() -> Bool {
        MainActor.assumeIsolated {
            guard peekPanel == nil else { return true }
            model.startTracking()
            peekPanel = PeekPanel(model: model)
            model.onLayoutChange = { [weak self] in
                MainActor.assumeIsolated { self?.placePanels() }
            }
            model.onFullscreenCheck = { [weak self] in
                MainActor.assumeIsolated { self?.updateFullscreenVisibility() }
            }
            model.onPeekChange = { [weak self] state in
                MainActor.assumeIsolated { self?.updatePeek(state) }
            }
            model.onClockClick = { [weak self] in
                MainActor.assumeIsolated { self?.toggleCalendar() }
            }
            model.pointerInPeekZone = { [weak self] in
                MainActor.assumeIsolated { self?.pointerInPeekZone() ?? false }
            }
            placePanels()
            updateFullscreenVisibility()
            return true
        }
    }

    func stop() {
        MainActor.assumeIsolated {
            model.stopTracking()
            peekPanel?.orderOut(nil)
            peekPanel = nil
            closeCalendar()
            calendarPanel = nil
            edgeTimer?.invalidate(); edgeTimer = nil
            fullscreenDisplays = []
            revealedDisplays = []
            for p in panels { p.orderOut(nil) }
            panels = []
            TaskbarLayout.bottomInset = 0
            TaskbarLayout.reservedDisplays = []
        }
    }

    // MARK: Calendar popup

    @MainActor
    private func toggleCalendar() {
        if calendarPanel?.isVisible == true { closeCalendar(); return }
        let p = calendarPanel ?? CalendarPanel()
        calendarPanel = p
        let cursor = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) })
            ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let f = screen.frame
        let w: CGFloat = 260, h: CGFloat = 290
        p.setFrame(NSRect(x: f.maxX - w - 12, y: f.minY + TaskbarMetrics.barHeight + 8, width: w, height: h), display: true)
        p.orderFrontRegardless()
        calMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeCalendar() }
        }
    }

    @MainActor
    private func closeCalendar() {
        if let m = calMonitor { NSEvent.removeMonitor(m); calMonitor = nil }
        calendarPanel?.orderOut(nil)
    }

    /// Re-place the bars when the "all screens" setting or the display layout
    /// changes. Recreates one panel per target screen.
    @MainActor
    func placePanels() {
        guard peekPanel != nil else { return }   // only while running
        let targets = allScreens
            ? NSScreen.screens
            : [NSScreen.main ?? NSScreen.screens.first].compactMap { $0 }
        for p in panels { p.orderOut(nil) }
        panels = targets.map { screen in
            let p = TaskbarPanel(model: model)
            p.place(on: screen)
            if !Self.isCoveredByWindow(screen.displayID) { p.orderFrontRegardless() }
            return p
        }
        TaskbarLayout.bottomInset = TaskbarMetrics.barHeight
        TaskbarLayout.reservedDisplays = Set(targets.map { $0.displayID })
    }

    /// Hides the bar on any display where a window fills the whole screen
    /// (native fullscreen, or a browser's F11 / video fullscreen). While it is
    /// hidden, pushing the pointer to the bottom edge slides it back; moving
    /// away hides it again. Normal windows bring it back for good.
    @MainActor
    private func updateFullscreenVisibility() {
        let now = Set(panels.map { $0.displayID }.filter { Self.isCoveredByWindow($0) })
        if now != fullscreenDisplays { trace("taskbar", "fullscreen displays \(fullscreenDisplays) -> \(now)") }
        fullscreenDisplays = now
        revealedDisplays.formIntersection(fullscreenDisplays)
        applyBarVisibility()
        // Poll the pointer only while a fullscreen window is up; global
        // mouse-moved events are not reliably delivered in fullscreen Spaces.
        if fullscreenDisplays.isEmpty {
            edgeTimer?.invalidate(); edgeTimer = nil
        } else if edgeTimer == nil {
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerMoved() }
            }
            RunLoop.main.add(t, forMode: .common)
            edgeTimer = t
        }
    }

    @MainActor
    private func applyBarVisibility() {
        for p in panels {
            let hide = fullscreenDisplays.contains(p.displayID) && !revealedDisplays.contains(p.displayID)
            if hide, p.isVisible {
                p.orderOut(nil)
                if peekPanel?.isVisible == true { model.hoverExit() }
            } else if !hide, !p.isVisible {
                p.orderFrontRegardless()
            }
        }
    }

    @MainActor
    private func pointerMoved() {
        let loc = NSEvent.mouseLocation
        var changed = false
        for p in panels where fullscreenDisplays.contains(p.displayID) {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == p.displayID }) else { continue }
            let f = screen.frame
            if revealedDisplays.contains(p.displayID) {
                // Stay while the pointer is on the bar, its popup or the calendar.
                let onBar = f.contains(loc) && loc.y <= f.minY + TaskbarMetrics.barHeight + 4
                if !onBar, !pointerInPeekZone(), calendarPanel?.isVisible != true {
                    revealedDisplays.remove(p.displayID); changed = true
                }
            } else if f.contains(loc) || (loc.x >= f.minX && loc.x <= f.maxX && loc.y <= f.minY + 1 && loc.y >= f.minY - 1) {
                if loc.y <= f.minY + 1 { revealedDisplays.insert(p.displayID); changed = true }
            }
        }
        if changed {
            trace("taskbar", "revealed \(revealedDisplays) pointer \(loc)")
            applyBarVisibility()
        }
    }

    /// True if an ordinary window on the current Space covers the display
    /// edge to edge, menu bar area included (a maximized window never does).
    private static func isCoveredByWindow(_ display: CGDirectDisplayID) -> Bool {
        let d = CGDisplayBounds(display)
        // A notched display's native fullscreen window starts below the notch
        // band, not at the very top edge.
        let notch = NSScreen.screens.first { $0.displayID == display }?.safeAreaInsets.top ?? 0
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let me = getpid()
        let top = d.minY + notch + 2, bottom = d.maxY - 2
        // Full-width layer-0 windows per owner, as vertical spans. One window
        // usually covers the display; Terminal's native fullscreen is split
        // into a tab bar window plus a content window, so spans are merged.
        var spans: [pid_t: [(lo: CGFloat, hi: CGFloat)]] = [:]
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
            guard b.minX <= d.minX + 2, b.maxX >= d.maxX - 2 else { continue }
            if b.minY <= top, b.maxY >= bottom { return true }
            spans[pid, default: []].append((b.minY, b.maxY))
        }
        for (_, list) in spans where list.count > 1 {
            var reach = top
            var progressed = true
            // Grow a covered run downward from the top edge.
            while progressed, reach < bottom {
                progressed = false
                for s in list where s.lo <= reach + 2 && s.hi > reach { reach = s.hi; progressed = true }
            }
            if reach >= bottom { return true }
        }
        return false
    }

    /// The popup, plus the strip below it down to the screen edge (the gap
    /// and the taskbar icons under it), so moving from the icon to the popup
    /// never closes it.
    @MainActor
    private func pointerInPeekZone() -> Bool {
        guard let p = peekPanel, p.isVisible else { return false }
        let f = p.frame
        let screenBottom = NSScreen.screens.first(where: { $0.frame.intersects(f) })?.frame.minY ?? 0
        let zone = NSRect(x: f.minX - 8, y: screenBottom, width: f.width + 16, height: f.maxY - screenBottom)
        return zone.contains(NSEvent.mouseLocation)
    }

    @MainActor
    private func updatePeek(_ state: TaskbarModel.Peek?) {
        guard let peekPanel else { return }
        let cursor = NSEvent.mouseLocation
        guard let state, let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) })
            ?? NSScreen.main ?? NSScreen.screens.first else {
            peekPanel.orderOut(nil)
            return
        }
        let f = screen.frame
        let cardW: CGFloat = 158        // 150 card + 8 spacing
        let width = min(CGFloat(state.windows.count) * cardW + 12, f.width - 40)
        let height: CGFloat = 150
        var x = state.anchorX - width / 2
        x = max(f.minX + 8, min(x, f.maxX - width - 8))
        let y = f.minY + TaskbarMetrics.barHeight + 6
        peekPanel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        peekPanel.orderFrontRegardless()
    }
}

// MARK: - Model

/// One entry on the taskbar. Identified by app (bundle id), so there is one
/// button per app whether it is pinned, running, or both.
struct TaskbarApp: Identifiable, Equatable {
    let id: String          // bundle id, or "pid:<n>" for the rare app without one
    let bundleID: String?
    let name: String
    let icon: NSImage?
    let pid: pid_t?         // nil when pinned but not running
    /// Every running process of this app (several when it was launched with
    /// `open -n`), `pid` first. Windows are gathered from all of them.
    var pids: [pid_t] = []
    let isPinned: Bool
    var isActive: Bool
    var windowCount = 0
    /// The windows' CGWindowIDs in the popup's order (0 where unknown).
    var windowIDs: [CGWindowID] = []
    /// Index (in the popup's order) of the app's focused window.
    var focusedWindow: Int?
    var isRunning: Bool { pid != nil }

    static func == (a: TaskbarApp, b: TaskbarApp) -> Bool {
        a.id == b.id && a.isActive == b.isActive && a.isPinned == b.isPinned
            && a.isRunning == b.isRunning && a.name == b.name
            && a.windowCount == b.windowCount && a.focusedWindow == b.focusedWindow
            && a.pids == b.pids
    }
}

/// Tracks pinned + running apps and drives the taskbar view. Rebuilds only on
/// app launch / quit / switch (and pin changes), so it is otherwise idle.
final class TaskbarModel: ObservableObject, @unchecked Sendable {
    @Published private(set) var apps: [TaskbarApp] = []
    @Published private(set) var peek: Peek?
    var onLayoutChange: (() -> Void)?
    /// Set by the feature: hide the bars on a display a window is covering
    /// edge to edge (native or browser fullscreen), show them again after.
    var onFullscreenCheck: (() -> Void)?
    var onPeekChange: ((Peek?) -> Void)?
    /// Set by the feature: whether the pointer is over the popup or the path to it.
    var pointerInPeekZone: (() -> Bool)?
    var onStartButton: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onClockClick: (() -> Void)?

    struct TaskbarWindow: Identifiable {
        let id: Int
        let title: String
        /// nil for a window on another Space that accessibility cannot list.
        let element: AXUIElement?
        let pid: pid_t
        let windowID: CGWindowID
    }

    struct Peek: Identifiable {
        let id = UUID()
        let pids: [pid_t]
        let anchorX: CGFloat
        let windows: [TaskbarWindow]
    }

    /// Window thumbnails for the current hover popover, keyed by CGWindowID.
    /// Filled asynchronously and cleared when the popover closes.
    @Published private(set) var thumbnails: [CGWindowID: NSImage] = [:]
    /// Kept across hovers so re-opening a popover shows thumbnails instantly
    /// while fresh ones capture in the background. Bounded to avoid growth.
    private var thumbCache: [CGWindowID: NSImage] = [:]

    private let defaults = UserDefaults.standard
    private var pinned: [String]                 // pinned bundle ids, in order
    private var unpinnedOrder: [String] = []     // manual order of running unpinned apps
    private var observers: [NSObjectProtocol] = []
    private var showWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var rightClickMonitor: Any?
    private var inputMonitors: [Any] = []
    private var refreshWork: DispatchWorkItem?
    /// A window we just raised, trusted over the app's own (possibly stale)
    /// focus report until `until`.
    private var pendingFocus: (pid: pid_t, windowID: CGWindowID, until: Date)?

    private let hidden: Set<String> = ["com.apple.tips"]
    /// Windows on other Spaces by pid, refreshed on each rebuild.
    private var otherSpace: [pid_t: [(id: CGWindowID, title: String)]] = [:]

    init() {
        pinned = defaults.stringArray(forKey: "taskbarPinned") ?? []
    }

    @MainActor
    func startTracking() {
        let wc = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        observers = names.map { name in
            wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.rebuild()
                    // A launching app opens its first window a moment later.
                    if name == NSWorkspace.didLaunchApplicationNotification { self?.scheduleRefresh(after: 1.0) }
                }
            }
        }
        // Windows open, close and change focus without any app-level
        // notification, but nearly always right after a click or key press,
        // so refresh the window dots shortly after input instead of polling.
        let mask: NSEvent.EventTypeMask = [.leftMouseUp, .keyUp]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }) { inputMonitors.append(m) }
        // Alt-Tab and the popup cards announce the window they raise; move the
        // dash right away instead of waiting for the app to report focus.
        observers.append(NotificationCenter.default.addObserver(
            forName: .windowRaised, object: nil, queue: nil) { [weak self] note in
                guard let pid = note.userInfo?["pid"] as? pid_t,
                      let wid = note.userInfo?["windowID"] as? CGWindowID else { return }
                MainActor.assumeIsolated { self?.markRaised(pid: pid, windowID: wid) }
        })
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
            return e
        }) { inputMonitors.append(m) }
        // Entering or leaving fullscreen switches Space; the animation runs
        // ~0.7s, so check once straight away and once after it settles.
        observers.append(wc.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onFullscreenCheck?()
                    self?.scheduleRefresh(after: 0.8)
                }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onLayoutChange?() }
        })
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] e in
            MainActor.assumeIsolated {
                self?.showWork?.cancel()
                self?.setPeek(nil)
            }
            return e
        }
        rebuild()
    }

    @MainActor
    func stopTracking() {
        let wc = NSWorkspace.shared.notificationCenter
        for o in observers { wc.removeObserver(o); NotificationCenter.default.removeObserver(o) }
        observers = []
        if let m = rightClickMonitor { NSEvent.removeMonitor(m); rightClickMonitor = nil }
        inputMonitors.forEach { NSEvent.removeMonitor($0) }
        inputMonitors = []
        refreshWork?.cancel()
        apps = []
        setPeek(nil)
    }

    @MainActor
    private func markRaised(pid: pid_t, windowID: CGWindowID) {
        pendingFocus = windowID == 0 ? nil : (pid, windowID, Date().addingTimeInterval(0.6))
        apps = apps.map { a in
            var a = a
            a.isActive = a.pids.contains(pid)
            if a.pids.contains(pid), windowID != 0, let i = a.windowIDs.firstIndex(of: windowID) { a.focusedWindow = i }
            return a
        }
        // Confirm once the app has caught up (a quicker read can still see the
        // old focus and flick the dash back).
        scheduleRefresh(after: 0.6)
    }

    /// Debounced rebuild: typing or clicking in bursts refreshes once after.
    @MainActor
    private func scheduleRefresh(after delay: TimeInterval = 0.3) {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.rebuild() } }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    @MainActor
    private func rebuild() {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { !hidden.contains($0.bundleIdentifier ?? "") }
        // key -> app, plus launch order. The first instance of each app is the
        // one the button activates; the others only contribute their windows.
        var appByKey: [String: NSRunningApplication] = [:]
        var instancesByKey: [String: [NSRunningApplication]] = [:]
        var launchOrder: [String] = []
        for app in running {
            let key = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
            if appByKey[key] == nil { appByKey[key] = app; launchOrder.append(key) }
            instancesByKey[key, default: []].append(app)
        }

        otherSpace = AXWindow.otherSpaceWindows()
        var result: [TaskbarApp] = []
        // Pinned block, in pinned order (running or not).
        for b in pinned {
            if let app = appByKey[b], !finderButClosed(b, app) {
                result.append(make(app, instances: instancesByKey[b] ?? [app], pinned: true, frontPID: frontPID))
            } else if let entry = pinnedEntry(bundleID: b) {
                result.append(entry)   // not running (or Finder with no window) -> closed look
            }
        }
        // Unpinned running block, honouring the manual drag order; newly-launched
        // apps join at the end, and quit apps drop out.
        let unpinnedKeys = launchOrder.filter { !pinned.contains($0) }
        let present = Set(unpinnedKeys)
        var order = unpinnedOrder.filter { present.contains($0) }
        for k in unpinnedKeys where !order.contains(k) { order.append(k) }
        unpinnedOrder = order
        for k in order {
            guard let app = appByKey[k], !finderButClosed(k, app) else { continue }
            result.append(make(app, instances: instancesByKey[k] ?? [app], pinned: false, frontPID: frontPID))
        }
        apps = result
        onFullscreenCheck?()
    }

    /// Finder is always running, so treat it as "open" only when it actually has
    /// a window (like the Windows File Explorer button).
    private func finderButClosed(_ key: String, _ app: NSRunningApplication) -> Bool {
        key == "com.apple.finder" && AXWindow.windowList(pid: app.processIdentifier).isEmpty
    }

    private func make(_ app: NSRunningApplication, instances: [NSRunningApplication],
                      pinned: Bool, frontPID: pid_t?) -> TaskbarApp {
        let b = app.bundleIdentifier
        let isFinder = b == "com.apple.finder"
        let pids = instances.map(\.processIdentifier)
        var item = TaskbarApp(id: b ?? "pid:\(app.processIdentifier)",
                          bundleID: b,
                          name: isFinder ? "File Explorer" : (app.localizedName ?? "App"),
                          icon: app.icon,
                          pid: app.processIdentifier,
                          isPinned: pinned,
                          isActive: frontPID.map { pids.contains($0) } ?? false)
        item.pids = pids
        // All instances' windows, one process after the other (the popup uses
        // the same order, so dot N is card N).
        var ids: [CGWindowID] = []
        var focused: Int?
        for pid in pids {
            let wins = AXWindow.orderedWindows(pid: pid)
            if let f = wins.focused, focused == nil || pid == frontPID { focused = ids.count + f }
            ids += wins.windows.map(\.id)
            // Then the pid's windows on other Spaces, in the popup's order too.
            let known = Set(wins.windows.map(\.id))
            ids += (otherSpace[pid] ?? []).map(\.id).filter { !known.contains($0) }
        }
        item.windowCount = ids.count
        item.windowIDs = ids
        item.focusedWindow = focused
        if let p = pendingFocus, pids.contains(p.pid), Date() < p.until,
           let i = item.windowIDs.firstIndex(of: p.windowID) {
            item.focusedWindow = i
        }
        return item
    }

    /// A pinned app that is not running, resolved from its bundle id.
    private func pinnedEntry(bundleID b: String) -> TaskbarApp? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) else { return nil }
        let isFinder = b == "com.apple.finder"
        let name = isFinder ? "File Explorer"
            : FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return TaskbarApp(id: b, bundleID: b, name: name,
                          icon: NSWorkspace.shared.icon(forFile: url.path),
                          pid: nil, isPinned: true, isActive: false)
    }

    // MARK: Pinning

    @MainActor
    func pin(_ item: TaskbarApp) {
        guard let b = item.bundleID, !pinned.contains(b) else { return }
        pinned.append(b); savePinned(); rebuild()
    }

    @MainActor
    func unpin(_ item: TaskbarApp) {
        guard let b = item.bundleID else { return }
        pinned.removeAll { $0 == b }; savePinned(); rebuild()
    }

    /// Reorder within the pinned list: move `id` to just before `targetId`.
    @MainActor
    func movePinned(_ id: String, before targetId: String) {
        guard pinned.contains(id), pinned.contains(targetId), id != targetId else { return }
        pinned.removeAll { $0 == id }
        if let ti = pinned.firstIndex(of: targetId) { pinned.insert(id, at: ti) }
        else { pinned.append(id) }
        savePinned(); rebuild()
    }

    /// Reorder within the unpinned (running) block.
    @MainActor
    func moveUnpinned(_ id: String, before targetId: String) {
        guard unpinnedOrder.contains(id), unpinnedOrder.contains(targetId), id != targetId else { return }
        unpinnedOrder.removeAll { $0 == id }
        if let ti = unpinnedOrder.firstIndex(of: targetId) { unpinnedOrder.insert(id, at: ti) }
        else { unpinnedOrder.append(id) }
        rebuild()
    }

    /// Drag one icon before another. Reorders within whichever block both belong
    /// to (pinned or unpinned); dragging across the two blocks is a no-op.
    @MainActor
    func reorder(_ id: String, before targetId: String) {
        let idPinned = pinned.contains(id), targetPinned = pinned.contains(targetId)
        if idPinned && targetPinned { movePinned(id, before: targetId) }
        else if !idPinned && !targetPinned { moveUnpinned(id, before: targetId) }
    }

    /// Move an icon to the end of its block (dropped past the last icon).
    @MainActor
    func moveToEnd(_ id: String) {
        if pinned.contains(id) {
            pinned.removeAll { $0 == id }; pinned.append(id); savePinned(); rebuild()
        } else if unpinnedOrder.contains(id) {
            unpinnedOrder.removeAll { $0 == id }; unpinnedOrder.append(id); rebuild()
        }
    }

    private func savePinned() { defaults.set(pinned, forKey: "taskbarPinned") }

    // MARK: Actions

    @MainActor
    func focus(_ item: TaskbarApp) {
        setPeek(nil)
        if item.bundleID == "com.apple.finder" { openFinderWindow(); return }
        // Our own icon (shown while Settings is open). Asking macOS to activate
        // ourselves from our own non-activating panel is ignored, so raise the
        // window directly.
        if item.pid == ProcessInfo.processInfo.processIdentifier { focusSelf(); return }
        // Already frontmost: minimize its window, like clicking a Windows taskbar
        // button for the active app.
        if item.isActive, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? item.pid {
            if minimizeFocusedWindow(pid: pid) {
                // macOS leaves the app active with nothing on screen, so the
                // taskbar kept it highlighted and the next click did nothing.
                // Move focus to the window underneath, like Windows.
                focusNextApp(excluding: pid)
            } else {
                // Highlighted but nothing visible: bring a window back.
                NSRunningApplication(processIdentifier: pid)?.activate(options: [])
                unminimizeIfAllHidden(pid: pid)
            }
            return
        }
        if let first = item.pid {
            // With several processes, activate one that actually has a window.
            let pid = item.pids.count > 1
                ? (item.pids.first { !AXWindow.windowList(pid: $0, timeout: 0.3).isEmpty } ?? first)
                : first
            NSRunningApplication(processIdentifier: pid)?.activate(options: [])
            unminimizeIfAllHidden(pid: pid)
        } else if let b = item.bundleID,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    @MainActor
    private func focusSelf() {
        let windows = NSApp.windows.filter { $0.styleMask.contains(.titled) && !($0 is NSPanel) }
        if NSApp.isActive, let key = NSApp.keyWindow, windows.contains(key), !key.isMiniaturized {
            key.miniaturize(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        for w in windows where w.isVisible || w.isMiniaturized {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        }
    }

    /// Window each app last had minimised from the taskbar, restored first.
    private var lastMinimized: [pid_t: AXUIElement] = [:]

    /// Minimises the app's focused window; false if it had no visible one.
    @discardableResult
    private func minimizeFocusedWindow(pid: pid_t) -> Bool {
        let appEl = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let w = winRef, CFGetTypeID(w) == AXUIElementGetTypeID() else { return false }
        let win = w as! AXUIElement
        var m: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &m)
        if (m as? Bool) == true { return false }
        AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        lastMinimized[pid] = win
        return true
    }

    /// Activate the app owning the frontmost normal window that isn't `pid`'s
    /// (Finder if there is none, i.e. the desktop).
    private func focusNextApp(excluding pid: pid_t) {
        let me = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list {   // front to back
            guard let owner = w[kCGWindowOwnerPID as String] as? pid_t, owner != pid, owner != me,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  (b["Width"] ?? 0) >= 100, (b["Height"] ?? 0) >= 100,
                  let app = NSRunningApplication(processIdentifier: owner),
                  app.activationPolicy == .regular else { continue }
            app.activate(options: [])
            return
        }
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate(options: [])
    }

    /// If clicking an app that has only minimized windows, restore one.
    private func unminimizeIfAllHidden(pid: pid_t) {
        let appEl = AXUIElementCreateApplication(pid)
        var winsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let arr = winsRef as? [AXUIElement], !arr.isEmpty else {
            reopen(pid: pid)
            return
        }
        for w in arr {
            var m: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &m)
            if (m as? Bool) == false { return }         // a visible window exists
        }
        // Prefer the window the taskbar minimised; fall back to the first.
        let last = lastMinimized.removeValue(forKey: pid).flatMap { l in arr.first { CFEqual($0, l) } }
        if let target = last ?? arr.first {
            AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        }
    }

    /// Running but with its window closed (Teams, Slack, Mail…): activating
    /// alone shows nothing. Opening the app again sends the same "reopen"
    /// request a Dock click does, which makes it bring its main window back.
    private func reopen(pid: pid_t) {
        guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    private func openFinderWindow() {
        let script = "tell application \"Finder\"\nactivate\nopen (make new Finder window)\nend tell"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }

    func quit(_ item: TaskbarApp) {
        if let pid = item.pid { NSRunningApplication(processIdentifier: pid)?.terminate() }
    }

    /// New window: Cmd+N in the running app, or just launch it if it is closed.
    @MainActor
    func newWindow(_ item: TaskbarApp) {
        guard let pid = item.pid, NSRunningApplication(processIdentifier: pid) != nil else {
            focus(item); return
        }
        AXWindow.openNewWindow(pid: pid)
    }

    @MainActor
    func raise(_ win: TaskbarWindow) {
        setPeek(nil)
        if let el = win.element { AXWindow.raise(el, pid: win.pid) }
        else { AXWindow.focusAcrossSpaces(windowID: win.windowID, pid: win.pid) }
    }

    // MARK: Hover popover

    @MainActor
    func hoverEnter(_ item: TaskbarApp) {
        closeWork?.cancel()
        showWork?.cancel()
        guard item.pid != nil else { return }   // not running: nothing to show
        let pids = item.pids
        let x = NSEvent.mouseLocation.x
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.showPeek(pids: pids, anchorX: x) }
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// Hover-exit events alone are unreliable here (a slow move across the gap
    /// outlasts the delay, and the bar re-rendering on any app launch or
    /// activation fires a spurious exit), which closed the popup at random.
    /// So closing only happens once the pointer has really left the popup and
    /// the strip below it; until then keep checking.
    @MainActor
    func hoverExit() {
        showWork?.cancel()
        scheduleClose(after: 0.3)
    }

    @MainActor
    private func scheduleClose(after delay: TimeInterval) {
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.peek != nil else { return }
                if self.pointerInPeekZone?() == true { self.scheduleClose(after: 0.15) }
                else { self.setPeek(nil) }
            }
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The ✕ on a popup card: close that window as if its red button was
    /// clicked, then refresh the popup with what is left.
    @MainActor
    func closeWindow(_ win: TaskbarWindow) {
        guard let peek else { return }
        var btn: CFTypeRef?
        let element = win.element ?? AXWindow.elementByRemoteToken(pid: win.pid, windowID: win.windowID)
        if let element, AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &btn) == .success,
           let b = btn, CFGetTypeID(b) == AXUIElementGetTypeID() {
            // Tell close-quits a window was closed on purpose (it cannot see
            // clicks inside Mac Fixes' own panels).
            NotificationCenter.default.post(name: .userClosedWindow, object: nil,
                                            userInfo: ["pid": win.pid])
            AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString)
        }
        let pids = peek.pids, x = peek.anchorX
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.peek?.pids == pids else { return }
                self.showPeek(pids: pids, anchorX: x)
            }
        }
    }

    @MainActor
    func keepPeek() { closeWork?.cancel() }

    @MainActor
    private func showPeek(pids: [pid_t], anchorX: CGFloat) {
        // Same order as the taskbar dots (per process, oldest first), so dot N is card N.
        var wins: [TaskbarWindow] = []
        for pid in pids {
            let cgList = AXWindow.onScreenWindowIDs(pid: pid)
            let ax = AXWindow.orderedWindows(pid: pid).windows
            for e in ax {
                wins.append(TaskbarWindow(id: wins.count, title: e.title, element: e.element, pid: pid,
                                          windowID: e.id != 0 ? e.id : matchWindowID(e.element, in: cgList)))
            }
            let known = Set(ax.map(\.id))
            for o in AXWindow.otherSpaceWindows()[pid] ?? [] where !known.contains(o.id) {
                wins.append(TaskbarWindow(id: wins.count, title: o.title, element: nil, pid: pid, windowID: o.id))
            }
        }
        guard !wins.isEmpty else { setPeek(nil); return }
        // Seed from cache so re-hovering shows thumbnails instantly; refresh below.
        var seeded: [CGWindowID: NSImage] = [:]
        for w in wins where w.windowID != 0 { if let img = thumbCache[w.windowID] { seeded[w.windowID] = img } }
        thumbnails = seeded
        setPeek(Peek(pids: pids, anchorX: anchorX, windows: wins))
        captureThumbnails(wins.compactMap { $0.windowID == 0 ? nil : $0.windowID })
    }

    /// Match an AX window to a CGWindowID by its on-screen frame.
    private func matchWindowID(_ element: AXUIElement, in list: [(id: CGWindowID, frame: CGRect)]) -> CGWindowID {
        guard let f = AXWindow.frame(of: element) else { return 0 }
        var best: (id: CGWindowID, dist: CGFloat) = (0, .greatestFiniteMagnitude)
        for w in list {
            let d = abs(w.frame.minX - f.minX) + abs(w.frame.minY - f.minY)
                + abs(w.frame.width - f.width) + abs(w.frame.height - f.height)
            if d < best.dist { best = (w.id, d) }
        }
        return best.dist < 20 ? best.id : 0
    }

    /// Grab a downscaled screenshot of each window, filling `thumbnails` as they
    /// arrive. Captured only while the popover is open and dropped when it
    /// closes, so nothing is retained (unlike AltTab's leak).
    @MainActor
    private func captureThumbnails(_ ids: [CGWindowID]) {
        guard !ids.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return }
            for id in ids {
                guard let self, self.peek != nil else { return }
                guard let win = content.windows.first(where: { $0.windowID == id }) else { continue }
                let cfg = SCStreamConfiguration()
                cfg.width = max(1, Int(win.frame.width / 2))
                cfg.height = max(1, Int(win.frame.height / 2))
                cfg.showsCursor = false
                if let cg = try? await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: win), configuration: cfg) {
                    let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    self.thumbCache[id] = img
                    if self.thumbCache.count > 60 { self.thumbCache = [id: img] }
                    self.thumbnails[id] = img
                }
            }
        }
    }

    @MainActor
    private func setPeek(_ new: Peek?) {
        peek = new
        if new == nil { thumbnails = [:] }
        onPeekChange?(new)
    }
}

// MARK: - View

struct TaskbarView: View {
    @ObservedObject var model: TaskbarModel
    @State private var draggingId: String?

    var body: some View {
        HStack(spacing: 6) {
            StartButton { model.onStartButton?() }
            Divider().frame(height: 30).padding(.horizontal, 2)
            ForEach(model.apps) { app in
                TaskbarButton(
                    app: app,
                    onClick: { model.focus(app) },
                    onNewWindow: { model.newWindow(app) },
                    onQuit: { model.quit(app) },
                    onPin: { model.pin(app) },
                    onUnpin: { model.unpin(app) },
                    onHoverEnter: { model.hoverEnter(app) },
                    onHoverExit: { model.hoverExit() })
                    .scaleEffect(draggingId == app.id ? 0.8 : 1)
                    .animation(.easeOut(duration: 0.15), value: draggingId)
                    .onDrag({
                        draggingId = app.id
                        return NSItemProvider(object: app.id as NSString)
                    }, preview: { Color.clear.frame(width: 1, height: 1) })   // no ghost image
                    .onDrop(of: [.text],
                            delegate: TaskbarDropDelegate(item: app, model: model, draggingId: $draggingId))
            }
            // Trailing filler doubles as a drop target: drop past the last icon
            // to move the dragged one to the end of its block.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onDrop(of: [.text], delegate: TaskbarEndDropDelegate(model: model, draggingId: $draggingId))
            TaskbarClock { model.onClockClick?() }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(VisualEffectBackground())      // consistent, focus-independent
        .contextMenu { Button("Taskbar Settings…") { model.onOpenSettings?() } }
    }
}

/// Reorders pinned icons as one is dragged over another.
private struct TaskbarDropDelegate: DropDelegate {
    let item: TaskbarApp
    let model: TaskbarModel
    @Binding var draggingId: String?

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingId, dragging != item.id else { return }
        MainActor.assumeIsolated { model.reorder(dragging, before: item.id) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { draggingId = nil; return true }
}

/// Drop onto the trailing filler to move the dragged icon to the end. Acts only
/// on the actual drop, not on hover — otherwise passing over this large filler
/// (which sits right next to the unpinned icons) would constantly yank the
/// dragged icon to the end and make reordering there impossible.
private struct TaskbarEndDropDelegate: DropDelegate {
    let model: TaskbarModel
    @Binding var draggingId: String?

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        if let dragging = draggingId { MainActor.assumeIsolated { model.moveToEnd(dragging) } }
        draggingId = nil
        return true
    }
}

/// Clock format, read from UserDefaults; "system" follows the Mac's own setting
/// (including 24-hour), other values are explicit `DateFormatter` templates.
enum ClockFormat {
    static func time(_ date: Date) -> String { render(date, key: "clockTimeFormat",
        system: { $0.formatted(.dateTime.hour().minute()) }) }
    static func date(_ date: Date) -> String { render(date, key: "clockDateFormat",
        system: { $0.formatted(.dateTime.day().month(.defaultDigits).year()) }) }

    private static func render(_ date: Date, key: String, system: (Date) -> String) -> String {
        let f = UserDefaults.standard.string(forKey: key) ?? "system"
        if f == "system" { return system(date) }
        let df = DateFormatter(); df.dateFormat = f
        return df.string(from: date)
    }
}

/// The taskbar clock: time over date, right-aligned. Click opens the calendar.
private struct TaskbarClock: View {
    let onClick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onClick) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(alignment: .trailing, spacing: 0) {
                    Text(ClockFormat.time(ctx.date))
                        .font(.system(size: 13, weight: .medium))
                    Text(ClockFormat.date(ctx.date))
                        .font(.system(size: 10))
                }
                .foregroundStyle(.primary)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(hovering ? 0.10 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The Windows-11-style logo: four squares, each with only its outer corner
/// rounded, filled with a subtle blue gradient.
private struct WindowsGrid: View {
    private let gap: CGFloat = 2
    private let r: CGFloat = 3.5

    var body: some View {
        // One gradient across the whole logo (top-left lightest, bottom-right
        // darkest), revealed through the four squares.
        LinearGradient(
            colors: [Color(red: 0.55, green: 0.87, blue: 0.98),
                     Color(red: 0.22, green: 0.45, blue: 0.72)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        .mask(
            VStack(spacing: gap) {
                HStack(spacing: gap) { square(topLeading: r);    square(topTrailing: r) }
                HStack(spacing: gap) { square(bottomLeading: r); square(bottomTrailing: r) }
            }
        )
    }

    private func square(topLeading: CGFloat = 0, topTrailing: CGFloat = 0,
                        bottomLeading: CGFloat = 0, bottomTrailing: CGFloat = 0) -> some View {
        UnevenRoundedRectangle(cornerRadii: .init(
            topLeading: topLeading, bottomLeading: bottomLeading,
            bottomTrailing: bottomTrailing, topTrailing: topTrailing))
            .fill(Color.black)
    }
}

/// The Start button at the left of the taskbar. Opens the Start menu.
private struct StartButton: View {
    let onClick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onClick) {
            WindowsGrid()
                .frame(width: 26, height: 26)
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(hovering ? 0.10 : 0)))
        }
        .buttonStyle(.plain)
        .help("Start")
        .onHover { hovering = $0 }
    }
}

private struct TaskbarButton: View {
    let app: TaskbarApp
    let onClick: () -> Void
    let onNewWindow: () -> Void
    let onQuit: () -> Void
    let onPin: () -> Void
    let onUnpin: () -> Void
    let onHoverEnter: () -> Void
    let onHoverExit: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onClick) {
            VStack(spacing: 2) {
                icon
                indicator
            }
            .padding(.horizontal, 4).padding(.vertical, 3)
            .opacity(app.isRunning ? 1 : 0.5)      // dim a pinned, closed app
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.primary.opacity(app.isActive ? 0.16 : (hovering ? 0.09 : 0)))
            )
        }
        .buttonStyle(.plain)
        .help(app.name)
        .onHover { inside in
            hovering = inside
            inside ? onHoverEnter() : onHoverExit()
        }
        .contextMenu {
            if app.isRunning { Button("New Window") { onNewWindow() } }
            if app.isPinned { Button("Unpin from taskbar") { onUnpin() } }
            else if app.bundleID != nil { Button("Pin to taskbar") { onPin() } }
            if app.isRunning {
                Divider()
                Button("Quit \(app.name)") { onQuit() }
            }
        }
    }

    /// One dot per open window, in the popup's order; the focused window of the
    /// frontmost app is a bright dash. A running app with no windows gets one
    /// faint dot, a pinned-but-closed app nothing.
    private static let maxDots = 5

    @ViewBuilder private var indicator: some View {
        let count = min(app.windowCount, Self.maxDots)
        let focused = app.isActive ? app.focusedWindow.map { min($0, Self.maxDots - 1) } : nil
        HStack(spacing: 3) {
            if count == 0 {
                Capsule().fill(Color.primary.opacity(app.isRunning ? 0.4 : 0)).frame(width: 5, height: 3)
            } else {
                ForEach(0..<count, id: \.self) { i in
                    Capsule()
                        .fill(Color.primary.opacity(i == focused ? 0.9 : 0.45))
                        .frame(width: i == focused ? 12 : 4, height: 3)
                }
            }
        }
        .frame(height: 3)
        .animation(.easeOut(duration: 0.15), value: focused)
    }

    @ViewBuilder private var icon: some View {
        if app.bundleID == "com.apple.finder" {
            Image(systemName: "folder.fill")
                .resizable().scaledToFit().frame(width: 34, height: 34)
                .foregroundStyle(Color(red: 0.98, green: 0.80, blue: 0.30))
        } else if let icon = app.icon {
            Image(nsImage: icon).resizable().scaledToFit().frame(width: 36, height: 36)
        } else {
            Image(systemName: "app.dashed").resizable().frame(width: 36, height: 36)
        }
    }
}

/// The hover popover: thumbnail cards of an app's open windows; click to raise.
private struct PeekView: View {
    @ObservedObject var model: TaskbarModel

    /// The card matching the taskbar's focus dash: the focused window of the
    /// frontmost app (card order is dot order).
    private var focusedIndex: Int? {
        guard let pid = model.peek?.pids.first,
              let app = model.apps.first(where: { $0.pid == pid }), app.isActive else { return nil }
        return app.focusedWindow
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(model.peek?.windows ?? []) { win in
                PeekCard(title: win.title, image: model.thumbnails[win.windowID],
                         isFocused: win.id == focusedIndex,
                         onClick: { model.raise(win) }, onClose: { model.closeWindow(win) })
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .glassPanel(12)
        .onHover { inside in inside ? model.keepPeek() : model.hoverExit() }
    }
}

private struct PeekCard: View {
    let title: String
    let image: NSImage?
    let isFocused: Bool
    let onClick: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onClick) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08))
                    if let image {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        Image(systemName: "macwindow").font(.system(size: 22)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 150, height: 94)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(isFocused ? Color.accentColor : Color.primary.opacity(hovering ? 0.5 : 0.12),
                            lineWidth: isFocused ? 2 : 1))
                Text(title).font(.caption).lineLimit(1).truncationMode(.tail).frame(width: 150)
            }
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.red.opacity(0.85)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Close window")
            .padding(4)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
        }
        .onHover { hovering = $0 }
    }
}

// MARK: - Calendar

private struct CalendarRoot: View {
    var body: some View {
        CalendarView()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .glassPanel(14)
    }
}

private struct CalendarView: View {
    @State private var anchor = Date()          // a date within the shown month
    private var cal: Calendar { Calendar.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Date(), format: .dateTime.weekday(.wide).month(.wide).day())
                .font(.headline)
            HStack {
                Text(anchor, format: .dateTime.month(.wide).year()).fontWeight(.semibold)
                Spacer()
                navButton("chevron.up") { shift(-1) }
                navButton("chevron.down") { shift(1) }
            }
            .foregroundStyle(.secondary)

            let cols = Array(repeating: GridItem(.fixed(30), spacing: 2), count: 7)
            LazyVGrid(columns: cols, spacing: 4) {
                ForEach(weekdays, id: \.self) {
                    Text($0).font(.caption2).foregroundStyle(.secondary).frame(width: 30)
                }
                ForEach(days, id: \.self) { day in cell(day) }
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    private func navButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func cell(_ date: Date) -> some View {
        let inMonth = cal.isDate(date, equalTo: anchor, toGranularity: .month)
        let today = cal.isDateInToday(date)
        return Text("\(cal.component(.day, from: date))")
            .font(.system(size: 12))
            .frame(width: 30, height: 30)
            .background(Circle().fill(today ? Color(red: 0.30, green: 0.76, blue: 1.0) : .clear))
            .foregroundStyle(today ? Color.white : (inMonth ? Color.primary : Color.primary.opacity(0.3)))
    }

    private func shift(_ n: Int) {
        if let d = cal.date(byAdding: .month, value: n, to: anchor) { anchor = d }
    }

    private var weekdays: [String] {
        let s = cal.shortWeekdaySymbols.map { String($0.prefix(2)) }
        let start = cal.firstWeekday - 1
        return Array(s[start...] + s[..<start])
    }

    /// Six weeks of dates covering the shown month, with leading/trailing days.
    private var days: [Date] {
        guard let first = cal.date(from: cal.dateComponents([.year, .month], from: anchor)) else { return [] }
        let weekday = cal.component(.weekday, from: first)
        let leading = (weekday - cal.firstWeekday + 7) % 7
        guard let start = cal.date(byAdding: .day, value: -leading, to: first) else { return [] }
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }
}

/// The calendar popup panel shown above the clock.
final class CalendarPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 260, height: 290),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingView(rootView: CalendarRoot())
        host.autoresizingMask = [.width, .height]
        contentView = host
    }
    override var canBecomeKey: Bool { true }
}

// MARK: - Panels

/// A borderless, non-activating panel pinned to the bottom edge, floating above
/// normal windows and present on every Space.
final class TaskbarPanel: NSPanel {
    private(set) var displayID: CGDirectDisplayID = 0

    init(model: TaskbarModel) {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        configureFloating()
        let host = NSHostingView(rootView: TaskbarView(model: model))
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    override var canBecomeKey: Bool { true }

    func place(on screen: NSScreen) {
        displayID = screen.displayID
        let f = screen.frame
        setFrame(NSRect(x: f.minX, y: f.minY, width: f.width, height: TaskbarMetrics.barHeight), display: true)
    }
}

/// The floating window-list popover shown above a hovered icon.
final class PeekPanel: NSPanel {
    init(model: TaskbarModel) {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        configureFloating()
        let host = NSHostingView(rootView: PeekView(model: model))
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    override var canBecomeKey: Bool { true }
}

private extension NSPanel {
    func configureFloating() {
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isMovable = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    }
}

extension Notification.Name {
    /// Mac Fixes closed a window on the user's behalf (userInfo "pid").
    static let userClosedWindow = Notification.Name("com.filipkin.macfixes.userClosedWindow")
    /// Mac Fixes raised a window (userInfo "pid", "windowID").
    static let windowRaised = Notification.Name("com.filipkin.macfixes.windowRaised")
}
