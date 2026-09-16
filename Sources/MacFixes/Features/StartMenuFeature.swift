import AppKit
import SwiftUI
import Carbon.HIToolbox

/// A Windows-style Start menu: tap the Windows key to open a search box, type,
/// and hit Return to launch an app. Apps only — no dictionary, web, or file
/// results, so it never opens the wrong thing.
///
/// Opening: a lone tap of the trigger modifier (Control by default, which is
/// what the physical Windows key sends once the external-keyboard swap maps
/// GUI -> Control). Detected with its own flags monitor, so it works without
/// turning on the intrusive keyboard-remap event tap.
final class StartMenuFeature: Feature, @unchecked Sendable {
    private var panel: StartMenuPanel?
    private let model = StartMenuModel()
    private var flagsMonitors: [Any] = []
    private var keyMonitors: [Any] = []
    private var openKeyMonitor: Any?
    private var clickAwayMonitor: Any?
    private var taskbarClickMonitor: Any?
    /// The app that was frontmost before we opened, to restore focus on close.
    private var previousApp: NSRunningApplication?

    /// Which modifier, tapped alone, opens the menu. Control == the Windows key
    /// after the swap.
    private let triggerMask: NSEvent.ModifierFlags = .control

    // Lone-tap detection (main-thread only).
    private var candidate = false
    private var sawOther = false
    private var candidateAt: TimeInterval = 0

    @discardableResult
    func start() -> Bool {
        MainActor.assumeIsolated {
            model.rebuildIndex()
            installTapMonitors()
            return true
        }
    }

    func stop() {
        MainActor.assumeIsolated {
            for m in flagsMonitors + keyMonitors { NSEvent.removeMonitor(m) }
            flagsMonitors = []; keyMonitors = []
            close(restoringFocus: false)
        }
    }

    // MARK: Lone-tap trigger

    @MainActor
    private func installTapMonitors() {
        guard flagsMonitors.isEmpty else { return }
        // flagsChanged: detect the lone modifier tap. Global fires for other
        // apps; local fires while our own menu is key (to toggle it shut).
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in
            let mods = e.modifierFlags
            MainActor.assumeIsolated { self?.handleFlags(mods) }
        }) { flagsMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in
            let mods = e.modifierFlags
            MainActor.assumeIsolated { self?.handleFlags(mods) }; return e
        }) { flagsMonitors.append(l) }
        // keyDown: a real key during the hold means it was a chord, not a tap.
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.noteKey() }
        }) { keyMonitors.append(g) }
    }

    @MainActor
    private func handleFlags(_ flags: NSEvent.ModifierFlags) {
        let mods = flags.intersection([.command, .option, .control, .shift, .function])
        let triggerDown = mods.contains(triggerMask)
        let onlyTrigger = triggerDown && mods.subtracting(triggerMask).isEmpty

        if triggerDown, onlyTrigger, !candidate {
            candidate = true
            sawOther = false
            candidateAt = ProcessInfo.processInfo.systemUptime
        } else if !triggerDown {
            if candidate, !sawOther,
               ProcessInfo.processInfo.systemUptime - candidateAt < 0.4 {
                toggle()
            }
            candidate = false
        } else {
            candidate = false   // another modifier joined; not a lone tap
        }
    }

    @MainActor private func noteKey() { if candidate { sawOther = true } }

    // MARK: Open / close

    @MainActor
    func toggle() {
        if panel?.isVisible == true { close(restoringFocus: true) } else { open() }
    }

    @MainActor
    private func open() {
        if model.isEmpty { model.rebuildIndex() }   // in case the Start button opened us before start()
        model.reset()
        previousApp = NSWorkspace.shared.frontmostApplication   // to restore focus on close
        let p = panel ?? StartMenuPanel(model: model)
        panel = p
        model.onRequestClose = { [weak self] restore in self?.close(restoringFocus: restore) }
        position(p)
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        // Grab focus now and again just after the window is key (first open of a
        // borderless panel can miss the first attempt).
        model.focusTick &+= 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.model.focusTick &+= 1 }
        installOpenKeyMonitor()
    }

    @MainActor
    private func close(restoringFocus restore: Bool) {
        for m in [openKeyMonitor, clickAwayMonitor, taskbarClickMonitor] { if let m { NSEvent.removeMonitor(m) } }
        openKeyMonitor = nil; clickAwayMonitor = nil; taskbarClickMonitor = nil
        panel?.orderOut(nil)
        // Return focus to whatever the user was in, unless we just launched.
        if restore, let prev = previousApp,
           prev.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            prev.activate()
        }
        previousApp = nil
    }

    @MainActor
    private func position(_ p: StartMenuPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let f = screen.frame
        let w: CGFloat = 380, h: CGFloat = 460
        let bottom = max(TaskbarLayout.bottomInset, 8)
        p.setFrame(NSRect(x: f.minX + 12, y: f.minY + bottom + 8, width: w, height: h), display: true)
    }

    /// While open, handle arrows / Return / Esc. Typing still reaches the field.
    @MainActor
    private func installOpenKeyMonitor() {
        guard openKeyMonitor == nil else { return }
        openKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            let code = Int(e.keyCode)
            let handled = MainActor.assumeIsolated { () -> Bool in
                switch code {
                case kVK_DownArrow: self.model.move(1); return true
                case kVK_UpArrow:   self.model.move(-1); return true
                case kVK_Return, kVK_ANSI_KeypadEnter:
                    if self.model.launchSelected() { self.close(restoringFocus: false) }
                    return true
                case kVK_Escape:    self.close(restoringFocus: true); return true
                default:            return false
                }
            }
            return handled ? nil : e
        }
        // A click in any other app (global monitor never fires for our own
        // panel) means the user clicked away — close.
        clickAwayMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(restoringFocus: true) }
        }
        // A click in one of our own other windows (the taskbar) also closes it.
        taskbarClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            guard let self else { return e }
            if e.window !== self.panel {
                MainActor.assumeIsolated { self.close(restoringFocus: true) }
            }
            return e
        }
    }
}

// MARK: - Model

final class StartMenuModel: ObservableObject, @unchecked Sendable {
    struct AppEntry: Identifiable, Hashable {
        let id: String      // full path
        let name: String
        let url: URL
        /// Computed (not stored) so we never retain a pile of icon bitmaps.
        var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
    }

    @Published var query: String = "" { didSet { filter() } }
    @Published private(set) var results: [AppEntry] = []
    @Published var selection = 0
    /// Bumped to make the search field grab focus each time the menu opens.
    @Published var focusTick = 0
    /// Set by the feature; the view calls it after launching to close (and not
    /// restore focus, since the launched app takes it).
    var onRequestClose: ((Bool) -> Void)?

    var isEmpty: Bool { index.isEmpty }

    private var index: [AppEntry] = []
    private let defaults = UserDefaults.standard
    /// How many times each app has been launched from here, for ranking.
    private var usage: [String: Int]

    // Roots to scan, each to a small depth (apps nested in vendor folders like
    // /Applications/Adobe…/App.app are common). We never descend into a .app.
    private let searchRoots: [(path: String, depth: Int)] = [
        ("/Applications", 3),
        ("/System/Applications", 2),
        ("/System/Applications/Utilities", 1),
        (NSHomeDirectory() + "/Applications", 3),
    ]

    init() {
        usage = (defaults.dictionary(forKey: "startMenuUsage") as? [String: Int]) ?? [:]
    }

    @MainActor
    func rebuildIndex() {
        var found: [String: AppEntry] = [:]
        for root in searchRoots { scan(root.path, depth: root.depth, into: &found) }
        for (name, url) in commonFolders() {
            found[url.path] = AppEntry(id: url.path, name: name, url: url)
        }
        index = found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        filter()
    }

    /// Standard user folders, openable in Finder like apps.
    private func commonFolders() -> [(String, URL)] {
        let fm = FileManager.default
        var out: [(String, URL)] = [("Home", fm.homeDirectoryForCurrentUser)]
        let dirs: [(FileManager.SearchPathDirectory, String)] = [
            (.downloadsDirectory, "Downloads"), (.documentDirectory, "Documents"),
            (.desktopDirectory, "Desktop"), (.picturesDirectory, "Pictures"),
            (.moviesDirectory, "Movies"), (.musicDirectory, "Music"),
        ]
        for (dir, name) in dirs {
            if let u = try? fm.url(for: dir, in: .userDomainMask, appropriateFor: nil, create: false) {
                out.append((name, u))
            }
        }
        return out
    }

    // MARK: System actions

    @MainActor
    func openSystemSettings() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor func sleepMac()    { osa("tell application \"System Events\" to sleep") }
    @MainActor func restartMac()  { osa("tell application \"System Events\" to restart") }
    @MainActor func shutDownMac() { osa("tell application \"System Events\" to shut down") }

    private func osa(_ script: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }

    private func scan(_ dir: String, depth: Int, into found: inout [String: AppEntry]) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for item in items {
            let path = dir + "/" + item
            if item.hasSuffix(".app") {
                let name = fm.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
                found[path] = AppEntry(id: path, name: name, url: URL(fileURLWithPath: path))
            } else if depth > 0 {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    scan(path, depth: depth - 1, into: &found)
                }
            }
        }
    }

    @MainActor
    func reset() { query = ""; selection = 0; filter() }

    private func filter() {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        selection = 0
        guard !q.isEmpty else {
            // No query: most-used first, then alphabetical.
            results = index
                .sorted { rank($0) != rank($1) ? rank($0) > rank($1)
                    : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .prefix(8).map { $0 }
            return
        }
        // Text tier: name prefix, then word-start, then anywhere. Within a tier,
        // more-used apps rank above closer text matches, then shorter names.
        let scored: [(AppEntry, Int)] = index.compactMap { app in
            let n = app.name.lowercased()
            if n.hasPrefix(q) { return (app, 0) }
            if n.contains(" " + q) { return (app, 1) }
            if n.contains(q) { return (app, 2) }
            return nil
        }
        results = scored.sorted { a, b in
            if a.1 != b.1 { return a.1 < b.1 }                 // text tier
            if rank(a.0) != rank(b.0) { return rank(a.0) > rank(b.0) }  // usage
            return a.0.name.count < b.0.name.count             // shorter name
        }.prefix(8).map(\.0)
    }

    private func rank(_ app: AppEntry) -> Int { usage[app.id] ?? 0 }

    @MainActor
    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    @MainActor
    @discardableResult
    func launch(_ app: AppEntry) -> Bool {
        usage[app.id, default: 0] += 1
        defaults.set(usage, forKey: "startMenuUsage")
        if app.url.pathExtension == "app" {
            return NSWorkspace.shared.open(app.url)
        }
        // A folder: open it in a NEW Finder window. Activating Finder is needed
        // for the window to appear; the new window is created frontmost, so the
        // old ones stay behind it rather than being pulled to the front.
        osa("tell application \"Finder\"\nactivate\nmake new Finder window to (POSIX file \"\(app.url.path)\")\nend tell")
        return true
    }

    @MainActor
    @discardableResult
    func launchSelected() -> Bool {
        guard results.indices.contains(selection) else { return false }
        return launch(results[selection])
    }
}

// MARK: - View

private struct StartMenuView: View {
    @ObservedObject var model: StartMenuModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search apps and folders…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .onSubmit { if model.launchSelected() { model.onRequestClose?(false) } }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { idx, app in
                        StartRow(app: app, selected: idx == model.selection) {
                            if model.launch(app) { model.onRequestClose?(false) }
                        }
                        .onHover { if $0 { model.selection = idx } }
                    }
                }
            }
            Spacer(minLength: 0)

            Divider()
            HStack(spacing: 4) {
                FooterButton(icon: "gearshape", help: "System Settings") {
                    model.openSystemSettings(); model.onRequestClose?(false)
                }
                Spacer()
                FooterButton(icon: "moon.fill", help: "Sleep") {
                    model.onRequestClose?(true); model.sleepMac()
                }
                FooterButton(icon: "arrow.clockwise", help: "Restart") { model.restartMac() }
                FooterButton(icon: "power", help: "Shut Down") { model.shutDownMac() }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onChange(of: model.focusTick) { searchFocused = true }
        .onAppear { searchFocused = true }
    }
}

private struct FooterButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(hovering ? 0.12 : 0)))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

private struct StartRow: View {
    let app: StartMenuModel.AppEntry
    let selected: Bool
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 10) {
                Image(nsImage: app.icon).resizable().frame(width: 24, height: 24)
                Text(app.name).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(selected ? 0.25 : 0)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Panel

/// A key, borderless panel — unlike the taskbar it must accept typing, so it
/// activates the app while open and returns focus when it closes.
final class StartMenuPanel: NSPanel {
    init(model: StartMenuModel) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 460),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false           // closing is handled by the click-away monitor
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: StartMenuView(model: model))
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    override var canBecomeKey: Bool { true }
}
