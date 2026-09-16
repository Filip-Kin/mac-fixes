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
            model.onPeekChange = { [weak self] state in
                MainActor.assumeIsolated { self?.updatePeek(state) }
            }
            model.onClockClick = { [weak self] in
                MainActor.assumeIsolated { self?.toggleCalendar() }
            }
            placePanels()
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
            p.orderFrontRegardless()
            return p
        }
        TaskbarLayout.bottomInset = TaskbarMetrics.barHeight
        TaskbarLayout.reservedDisplays = Set(targets.map { $0.displayID })
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
    let isPinned: Bool
    var isActive: Bool
    var isRunning: Bool { pid != nil }

    static func == (a: TaskbarApp, b: TaskbarApp) -> Bool {
        a.id == b.id && a.isActive == b.isActive && a.isPinned == b.isPinned
            && a.isRunning == b.isRunning && a.name == b.name
    }
}

/// Tracks pinned + running apps and drives the taskbar view. Rebuilds only on
/// app launch / quit / switch (and pin changes), so it is otherwise idle.
final class TaskbarModel: ObservableObject, @unchecked Sendable {
    @Published private(set) var apps: [TaskbarApp] = []
    @Published private(set) var peek: Peek?
    var onLayoutChange: (() -> Void)?
    var onPeekChange: ((Peek?) -> Void)?
    var onStartButton: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onClockClick: (() -> Void)?

    struct TaskbarWindow: Identifiable {
        let id: Int
        let title: String
        let element: AXUIElement
        let pid: pid_t
        let windowID: CGWindowID
    }

    struct Peek: Identifiable {
        let id = UUID()
        let pid: pid_t
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

    private let hidden: Set<String> = ["com.apple.tips"]

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
                MainActor.assumeIsolated { self?.rebuild() }
            }
        }
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
        apps = []
        setPeek(nil)
    }

    @MainActor
    private func rebuild() {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { !hidden.contains($0.bundleIdentifier ?? "") }
        // key -> app, plus launch order (first instance of each app wins).
        var appByKey: [String: NSRunningApplication] = [:]
        var launchOrder: [String] = []
        for app in running {
            let key = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
            if appByKey[key] == nil { appByKey[key] = app; launchOrder.append(key) }
        }

        var result: [TaskbarApp] = []
        // Pinned block, in pinned order (running or not).
        for b in pinned {
            if let app = appByKey[b], !finderButClosed(b, app) {
                result.append(make(app, pinned: true, frontPID: frontPID))
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
            result.append(make(app, pinned: false, frontPID: frontPID))
        }
        apps = result
    }

    /// Finder is always running, so treat it as "open" only when it actually has
    /// a window (like the Windows File Explorer button).
    private func finderButClosed(_ key: String, _ app: NSRunningApplication) -> Bool {
        key == "com.apple.finder" && AXWindow.windowList(pid: app.processIdentifier).isEmpty
    }

    private func make(_ app: NSRunningApplication, pinned: Bool, frontPID: pid_t?) -> TaskbarApp {
        let b = app.bundleIdentifier
        let isFinder = b == "com.apple.finder"
        return TaskbarApp(id: b ?? "pid:\(app.processIdentifier)",
                          bundleID: b,
                          name: isFinder ? "File Explorer" : (app.localizedName ?? "App"),
                          icon: app.icon,
                          pid: app.processIdentifier,
                          isPinned: pinned,
                          isActive: app.processIdentifier == frontPID)
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
        // Already frontmost: minimize its window, like clicking a Windows taskbar
        // button for the active app.
        if item.isActive, let pid = item.pid {
            minimizeFocusedWindow(pid: pid)
            return
        }
        if let pid = item.pid {
            NSRunningApplication(processIdentifier: pid)?.activate(options: [])
            unminimizeIfAllHidden(pid: pid)
        } else if let b = item.bundleID,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func minimizeFocusedWindow(pid: pid_t) {
        let appEl = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
           let w = winRef, CFGetTypeID(w) == AXUIElementGetTypeID() {
            AXUIElementSetAttributeValue(w as! AXUIElement, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        }
    }

    /// If clicking an app that has only minimized windows, restore one.
    private func unminimizeIfAllHidden(pid: pid_t) {
        let appEl = AXUIElementCreateApplication(pid)
        var winsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let arr = winsRef as? [AXUIElement], !arr.isEmpty else { return }
        for w in arr {
            var m: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &m)
            if (m as? Bool) == false { return }         // a visible window exists
        }
        if let first = arr.first {
            AXUIElementSetAttributeValue(first, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(first, kAXRaiseAction as CFString)
        }
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
        guard let pid = item.pid, let app = NSRunningApplication(processIdentifier: pid) else {
            focus(item); return
        }
        app.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let src = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_N), keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_N), keyDown: false)
            down?.flags = .maskCommand; up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
        }
    }

    @MainActor
    func raise(_ win: TaskbarWindow) {
        setPeek(nil)
        AXWindow.raise(win.element, pid: win.pid)
    }

    // MARK: Hover popover

    @MainActor
    func hoverEnter(_ item: TaskbarApp) {
        closeWork?.cancel()
        showWork?.cancel()
        guard let pid = item.pid else { return }   // not running: nothing to show
        let x = NSEvent.mouseLocation.x
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.showPeek(pid: pid, anchorX: x) }
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    @MainActor
    func hoverExit() {
        showWork?.cancel()
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.setPeek(nil) }
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    @MainActor
    func keepPeek() { closeWork?.cancel() }

    @MainActor
    private func showPeek(pid: pid_t, anchorX: CGFloat) {
        let cgList = AXWindow.onScreenWindowIDs(pid: pid)
        let wins = AXWindow.windowList(pid: pid).enumerated().map { (i, e) -> TaskbarWindow in
            TaskbarWindow(id: i, title: e.title, element: e.element, pid: pid,
                          windowID: matchWindowID(e.element, in: cgList))
        }
        guard wins.count > 1 else { setPeek(nil); return }
        // Seed from cache so re-hovering shows thumbnails instantly; refresh below.
        var seeded: [CGWindowID: NSImage] = [:]
        for w in wins where w.windowID != 0 { if let img = thumbCache[w.windowID] { seeded[w.windowID] = img } }
        thumbnails = seeded
        setPeek(Peek(pid: pid, anchorX: anchorX, windows: wins))
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
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
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
                // Running indicator: wide/bright when frontmost, a small line when
                // open in the background, nothing for a pinned-but-closed app.
                Capsule()
                    .fill(Color.primary.opacity(app.isActive ? 0.9 : (app.isRunning ? 0.4 : 0)))
                    .frame(width: app.isActive ? 16 : 5, height: 3)
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

    var body: some View {
        HStack(spacing: 8) {
            ForEach(model.peek?.windows ?? []) { win in
                PeekCard(title: win.title, image: model.thumbnails[win.windowID]) { model.raise(win) }
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
    let onClick: () -> Void
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
                    .stroke(Color.primary.opacity(hovering ? 0.5 : 0.12)))
                Text(title).font(.caption).lineLimit(1).truncationMode(.middle).frame(width: 150)
            }
        }
        .buttonStyle(.plain)
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
