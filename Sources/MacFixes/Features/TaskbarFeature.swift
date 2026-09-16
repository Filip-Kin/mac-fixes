import AppKit
import SwiftUI
import Carbon.HIToolbox

enum TaskbarMetrics {
    static let barHeight: CGFloat = 52
}

/// Space the taskbar reserves, read by `AXWindow.axVisibleFrame` so our window
/// snapping (maximize, halves, quarters, drag-snap) stops above the bar instead
/// of sliding under it. Only touched on the main actor.
enum TaskbarLayout {
    nonisolated(unsafe) static var bottomInset: CGFloat = 0
    nonisolated(unsafe) static var displayID: CGDirectDisplayID = 0

    /// True if the bar is visible and lives on this screen.
    static func reserves(_ screen: NSScreen) -> Bool {
        guard bottomInset > 0 else { return false }
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        return id == displayID
    }
}

/// A Windows-style taskbar: a strip along the bottom of the screen showing the
/// apps that are open, so you can see and switch what is running at a glance
/// without the Dock. Click an icon to switch; right-click for New Window / Quit;
/// hover an app with several windows to pick one from a list.
///
/// Runs above normal windows as a non-activating panel, so clicking a taskbar
/// button never steals focus from the app you are switching to.
final class TaskbarFeature: Feature, @unchecked Sendable {
    // Touched only on the main actor (via assumeIsolated below).
    private var panel: TaskbarPanel?
    private var peekPanel: PeekPanel?
    private let model = TaskbarModel()

    /// What the Start button does (wired to the Start menu by FeatureManager).
    @MainActor
    func setStartAction(_ action: @escaping () -> Void) {
        model.onStartButton = action
    }

    @discardableResult
    func start() -> Bool {
        MainActor.assumeIsolated {
            guard panel == nil else { return true }
            model.startTracking()
            let p = TaskbarPanel(model: model)
            p.place(on: NSScreen.main ?? NSScreen.screens.first)
            p.orderFrontRegardless()
            panel = p

            let peek = PeekPanel(model: model)
            peekPanel = peek

            // Re-place on display changes (resolution, screen add/remove).
            model.onLayoutChange = { [weak p] in
                p?.place(on: NSScreen.main ?? NSScreen.screens.first)
            }
            // Show / hide / position the hover popover.
            model.onPeekChange = { [weak self] state in
                MainActor.assumeIsolated { self?.updatePeek(state) }
            }
            return true
        }
    }

    func stop() {
        MainActor.assumeIsolated {
            model.stopTracking()
            peekPanel?.orderOut(nil)
            peekPanel = nil
            panel?.orderOut(nil)
            panel = nil
            TaskbarLayout.bottomInset = 0    // stop reserving space for snapping
        }
    }

    @MainActor
    private func updatePeek(_ state: TaskbarModel.Peek?) {
        guard let peekPanel else { return }
        guard let state, let screen = NSScreen.main ?? NSScreen.screens.first else {
            peekPanel.orderOut(nil)
            return
        }
        let width: CGFloat = 320
        let rowH: CGFloat = 26
        let height = min(CGFloat(state.windows.count), 10) * rowH + 16
        let f = screen.frame
        var x = state.anchorX - width / 2
        x = max(f.minX + 8, min(x, f.maxX - width - 8))
        let y = f.minY + TaskbarMetrics.barHeight + 6
        peekPanel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        peekPanel.orderFrontRegardless()
    }
}

// MARK: - Model

/// One entry on the taskbar.
struct TaskbarApp: Identifiable, Equatable {
    let id: pid_t          // process id (unique per running app)
    let bundleID: String?
    let name: String
    let icon: NSImage?
    var isActive: Bool

    static func == (a: TaskbarApp, b: TaskbarApp) -> Bool {
        a.id == b.id && a.isActive == b.isActive && a.name == b.name
    }
}

/// Tracks running apps and drives the taskbar view. Rebuilds only on app
/// launch / quit / switch, so it is effectively idle otherwise.
final class TaskbarModel: ObservableObject, @unchecked Sendable {
    @Published private(set) var apps: [TaskbarApp] = []
    @Published private(set) var peek: Peek?
    var onLayoutChange: (() -> Void)?
    var onPeekChange: ((Peek?) -> Void)?
    var onStartButton: (() -> Void)?

    /// One open window of an app, for the hover popover.
    struct TaskbarWindow: Identifiable {
        let id: Int
        let title: String
        let element: AXUIElement
        let pid: pid_t
    }

    /// The hover popover's state: which app, where to anchor, and its windows.
    struct Peek: Identifiable {
        let id = UUID()
        let pid: pid_t
        let anchorX: CGFloat
        let windows: [TaskbarWindow]
    }

    private var observers: [NSObjectProtocol] = []
    private var showWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var rightClickMonitor: Any?

    // Apple apps that auto-launch and clutter the bar but are almost never
    // things you switch to. Hidden unless the user pins them (later milestone).
    private let hidden: Set<String> = [
        "com.apple.tips",
    ]

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
        // Screen changes come through the default centre, not the workspace one.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onLayoutChange?() }
        })
        // Right-click on the bar shows the context menu, not the hover list.
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
        apps = running.map { app in
            let isFinder = app.bundleIdentifier == "com.apple.finder"
            return TaskbarApp(id: app.processIdentifier,
                       bundleID: app.bundleIdentifier,
                       name: isFinder ? "File Explorer" : (app.localizedName ?? "App"),
                       icon: app.icon,
                       isActive: app.processIdentifier == frontPID)
        }
    }

    // MARK: Actions

    @MainActor
    func focus(_ item: TaskbarApp) {
        setPeek(nil)
        // Finder always runs and its desktop counts as a "window" in AX, so we
        // can't tell if a real window is open. Clicking File Explorer just opens
        // a fresh Finder window, like Windows.
        if item.bundleID == "com.apple.finder" {
            let script = "tell application \"Finder\"\nactivate\nopen (make new Finder window)\nend tell"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            try? p.run()
            return
        }
        NSRunningApplication(processIdentifier: item.id)?.activate(options: [])
    }

    func quit(_ item: TaskbarApp) {
        NSRunningApplication(processIdentifier: item.id)?.terminate()
    }

    /// Bring the app forward and send Cmd+N — a new window (or document) in
    /// every app that follows the standard shortcut (Edge, Finder, browsers…).
    func newWindow(_ item: TaskbarApp) {
        guard let app = NSRunningApplication(processIdentifier: item.id) else { return }
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

    /// Mouse entered an app icon: after a short delay, show its window list
    /// (only if it has more than one window).
    @MainActor
    func hoverEnter(_ item: TaskbarApp) {
        closeWork?.cancel()
        showWork?.cancel()
        let pid = item.id
        let x = NSEvent.mouseLocation.x
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.showPeek(pid: pid, anchorX: x) }
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// Mouse left an icon (or the popover): close shortly, unless the mouse
    /// moves into the popover and cancels it.
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

    /// Mouse is over the popover: keep it open.
    @MainActor
    func keepPeek() { closeWork?.cancel() }

    @MainActor
    private func showPeek(pid: pid_t, anchorX: CGFloat) {
        let wins = AXWindow.windowList(pid: pid).enumerated().map {
            TaskbarWindow(id: $0.offset, title: $0.element.title, element: $0.element.element, pid: pid)
        }
        guard wins.count > 1 else { setPeek(nil); return }
        setPeek(Peek(pid: pid, anchorX: anchorX, windows: wins))
    }

    @MainActor
    private func setPeek(_ new: Peek?) {
        peek = new
        onPeekChange?(new)
    }
}

// MARK: - View

struct TaskbarView: View {
    @ObservedObject var model: TaskbarModel

    var body: some View {
        HStack(spacing: 6) {
            StartButton { model.onStartButton?() }
            Divider().frame(height: 30).padding(.horizontal, 2)
            ForEach(model.apps) { app in
                TaskbarButton(app: app,
                              onClick: { model.focus(app) },
                              onNewWindow: { model.newWindow(app) },
                              onQuit: { model.quit(app) },
                              onHoverEnter: { model.hoverEnter(app) },
                              onHoverExit: { model.hoverExit() })
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
    }
}

/// The Start button at the left of the taskbar. Opens the Start menu.
private struct StartButton: View {
    let onClick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onClick) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
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
    let onHoverEnter: () -> Void
    let onHoverExit: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onClick) {
            VStack(spacing: 3) {
                if app.bundleID == "com.apple.finder" {
                    // A plain file-explorer folder glyph in place of the Finder face.
                    Image(systemName: "folder.fill")
                        .resizable().scaledToFit().frame(width: 28, height: 28)
                        .foregroundStyle(Color(red: 0.98, green: 0.80, blue: 0.30))
                } else if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable().frame(width: 30, height: 30)
                } else {
                    Image(systemName: "app.dashed")
                        .resizable().frame(width: 30, height: 30)
                }
                // Running indicator, brighter when this app is frontmost.
                Capsule()
                    .fill(Color.primary.opacity(app.isActive ? 0.9 : 0.35))
                    .frame(width: app.isActive ? 18 : 6, height: 3)
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(app.isActive ? 0.14 : (hovering ? 0.08 : 0)))
            )
        }
        .buttonStyle(.plain)
        .help(app.name)
        .onHover { inside in
            hovering = inside
            inside ? onHoverEnter() : onHoverExit()
        }
        .contextMenu {
            Button("New Window") { onNewWindow() }
            Divider()
            Button("Quit \(app.name)") { onQuit() }
        }
    }
}

/// The hover popover: a list of an app's open windows, click one to raise it.
private struct PeekView: View {
    @ObservedObject var model: TaskbarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.peek?.windows ?? []) { win in
                PeekRow(title: win.title) { model.raise(win) }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onHover { inside in inside ? model.keepPeek() : model.hoverExit() }
    }
}

private struct PeekRow: View {
    let title: String
    let onClick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 6) {
                Image(systemName: "macwindow")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(hovering ? 0.10 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
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

    /// Non-activating panels never become key by default; allow it so buttons
    /// react on the first click without a prior focus click.
    override var canBecomeKey: Bool { true }

    func place(on screen: NSScreen?) {
        guard let screen else { return }
        let f = screen.frame
        setFrame(NSRect(x: f.minX, y: f.minY, width: f.width, height: TaskbarMetrics.barHeight), display: true)
        // Tell window snapping to keep clear of the bar on this screen.
        TaskbarLayout.bottomInset = TaskbarMetrics.barHeight
        TaskbarLayout.displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
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
    /// Shared setup for the taskbar's borderless floating panels.
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
