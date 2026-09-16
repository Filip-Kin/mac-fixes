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
        // Appear on the screen the cursor is on (which is the taskbar's screen).
        let cursor = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) })
            ?? NSScreen.main ?? NSScreen.screens.first else { return }
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
                    if self.model.runSelected() { self.close(restoringFocus: false) }
                    return true
                case kVK_Escape:    self.close(restoringFocus: true); return true
                default:            return false
                }
            }
            return handled ? nil : e
        }
        // A click in any other app (global monitor never fires for our own
        // panel) means the user clicked away — close, but keep the focus that
        // click just gave them (only a key-close restores the previous app).
        clickAwayMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(restoringFocus: false) }
        }
        // A click in one of our own other windows (the taskbar) also closes it.
        taskbarClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            guard let self else { return e }
            if e.window !== self.panel {
                MainActor.assumeIsolated { self.close(restoringFocus: false) }
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
    }

    /// A single search hit from any source (app, folder, file, setting, calc).
    struct SearchResult: Identifiable {
        enum Kind { case app, folder, file, setting, calculation }
        let id: String
        let title: String
        let subtitle: String
        let kind: Kind
        let iconPath: String?      // resolve to a file icon lazily
        let symbol: String?        // or an SF Symbol (settings, calc)
        let action: SRAction
        /// Computed so we never retain a pile of icon bitmaps.
        var icon: NSImage? { iconPath.map { NSWorkspace.shared.icon(forFile: $0) } }
    }

    enum SRAction {
        case openFile(URL)         // apps and files
        case openFolder(URL)       // a new Finder window
        case settings(String)      // an x-apple.systempreferences URL
        case copy(String)          // e.g. a calculator result
    }

    struct SettingsPane { let title: String; let url: String; let symbol: String; let keywords: [String] }

    @Published var query: String = "" { didSet { filter() } }
    @Published private(set) var results: [SearchResult] = []
    @Published var selection = 0
    /// Bumped to make the search field grab focus each time the menu opens.
    @Published var focusTick = 0
    /// Set by the feature; the view calls it after launching to close (and not
    /// restore focus, since the launched app takes it).
    var onRequestClose: ((Bool) -> Void)?

    var isEmpty: Bool { index.isEmpty }

    private var index: [AppEntry] = []
    private let defaults = UserDefaults.standard
    /// How many times each result has been launched from here, for ranking.
    private var usage: [String: Int]
    /// Bumped each keystroke so async file results from a stale query are dropped.
    private var searchGen = 0
    /// The synchronous hits for the current query, so async file hits can merge.
    private var lastScored: [(SearchResult, Int)] = []

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
        let q = query.trimmingCharacters(in: .whitespaces)
        selection = 0
        searchGen += 1
        guard !q.isEmpty else { results = defaultResults(); lastScored = []; return }

        var scored: [(SearchResult, Int)] = []
        // Scores are banded so kind wins first: calc > apps/settings > files.
        // That keeps a random file from outranking a matching app.
        // Calculator — floats to the top when the query is an expression.
        if let v = Calc.eval(q) {
            let text = Calc.format(v)
            scored.append((SearchResult(id: "calc", title: text, subtitle: "Calculator — Return to copy",
                                        kind: .calculation, iconPath: nil, symbol: "equal.square",
                                        action: .copy(text)), 2_000_000))
        }
        // Apps and folders.
        for app in index {
            guard let s = Self.fuzzyScore(q, app.name) else { continue }
            scored.append((appResult(app), 100_000 + s + min(rank(app.id), 25) * 6))
        }
        // System Settings panes (same band as apps, just below a matching app).
        for pane in Self.settingsPanes {
            guard let s = Self.bestScore(q, pane.title, pane.keywords) else { continue }
            scored.append((settingResult(pane), 100_000 + s - 30 + min(rank("set:" + pane.url), 25) * 6))
        }
        lastScored = scored
        results = topResults(scored)
        searchFiles(q, gen: searchGen)   // Spotlight, async
    }

    private func rank(_ id: String) -> Int { usage[id] ?? 0 }

    private func topResults(_ scored: [(SearchResult, Int)]) -> [SearchResult] {
        var seen = Set<String>()
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.title.count < $1.0.title.count }
            .filter { seen.insert($0.0.id).inserted }
            .prefix(9).map(\.0)
    }

    private func defaultResults() -> [SearchResult] {
        index.sorted { rank($0.id) != rank($1.id) ? rank($0.id) > rank($1.id)
            : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .prefix(8).map { appResult($0) }
    }

    private func appResult(_ app: AppEntry) -> SearchResult {
        let isApp = app.url.pathExtension == "app"
        return SearchResult(id: app.id, title: app.name, subtitle: isApp ? "Application" : "Folder",
                            kind: isApp ? .app : .folder, iconPath: app.url.path, symbol: nil,
                            action: isApp ? .openFile(app.url) : .openFolder(app.url))
    }

    private func settingResult(_ p: SettingsPane) -> SearchResult {
        SearchResult(id: "set:" + p.url, title: p.title, subtitle: "System Settings",
                     kind: .setting, iconPath: nil, symbol: p.symbol, action: .settings(p.url))
    }

    // MARK: Spotlight file search

    private func searchFiles(_ q: String, gen: Int) {
        guard q.count >= 3 else { return }   // short queries are too noisy
        Task.detached { [weak self] in
            let paths = Self.mdfind(q)
            await MainActor.run {
                guard let self, gen == self.searchGen else { return }   // query moved on
                let indexPaths = Set(self.index.map { $0.url.path })
                var fileScored: [(SearchResult, Int)] = []
                for path in paths {
                    if path.hasSuffix(".app") { continue }        // apps come from the index
                    if indexPaths.contains(path) { continue }     // no duplicates of indexed items
                    let name = (path as NSString).lastPathComponent
                    guard let s = Self.fuzzyScore(q, name) else { continue }
                    let url = URL(fileURLWithPath: path)
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                    fileScored.append((SearchResult(id: "file:" + path, title: name,
                                         subtitle: (path as NSString).deletingLastPathComponent,
                                         kind: isDir.boolValue ? .folder : .file, iconPath: path, symbol: nil,
                                         action: isDir.boolValue ? .openFolder(url) : .openFile(url)), s))
                    if fileScored.count >= 8 { break }
                }
                self.results = self.topResults(self.lastScored + fileScored)
            }
        }
    }

    private static func mdfind(_ q: String) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["-name", q]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let lines = (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
        return Array(lines.prefix(60))
    }

    /// Best fuzzy score across a title and its keywords.
    static func bestScore(_ q: String, _ title: String, _ keywords: [String]) -> Int? {
        var best = fuzzyScore(q, title)
        for k in keywords {
            if let s = fuzzyScore(q, k) { best = max(best ?? Int.min, s - 60) }
        }
        return best
    }

    static let settingsPanes: [SettingsPane] = [
        .init(title: "Wi-Fi", url: "x-apple.systempreferences:com.apple.wifi-settings-extension", symbol: "wifi", keywords: ["network", "internet", "wireless"]),
        .init(title: "Bluetooth", url: "x-apple.systempreferences:com.apple.BluetoothSettings", symbol: "dot.radiowaves.right", keywords: []),
        .init(title: "Displays", url: "x-apple.systempreferences:com.apple.Displays-Settings.extension", symbol: "display", keywords: ["monitor", "resolution", "screen"]),
        .init(title: "Sound", url: "x-apple.systempreferences:com.apple.Sound-Settings.extension", symbol: "speaker.wave.2", keywords: ["audio", "volume"]),
        .init(title: "Notifications", url: "x-apple.systempreferences:com.apple.Notifications-Settings.extension", symbol: "bell", keywords: []),
        .init(title: "Battery", url: "x-apple.systempreferences:com.apple.Battery-Settings.extension", symbol: "battery.100", keywords: ["power", "energy"]),
        .init(title: "Keyboard", url: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension", symbol: "keyboard", keywords: []),
        .init(title: "Trackpad", url: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension", symbol: "rectangle.and.hand.point.up.left", keywords: []),
        .init(title: "Mouse", url: "x-apple.systempreferences:com.apple.Mouse-Settings.extension", symbol: "computermouse", keywords: []),
        .init(title: "General", url: "x-apple.systempreferences:com.apple.systempreferences.GeneralSettings", symbol: "gearshape", keywords: ["about", "software update"]),
        .init(title: "Appearance", url: "x-apple.systempreferences:com.apple.Appearance-Settings.extension", symbol: "circle.lefthalf.filled", keywords: ["dark mode", "theme", "light"]),
        .init(title: "Wallpaper", url: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension", symbol: "photo", keywords: ["desktop", "background"]),
        .init(title: "Desktop & Dock", url: "x-apple.systempreferences:com.apple.Desktop-Settings.extension", symbol: "dock.rectangle", keywords: ["dock", "mission control", "hot corners", "stage manager"]),
        .init(title: "Accessibility", url: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension", symbol: "accessibility", keywords: []),
        .init(title: "Privacy & Security", url: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension", symbol: "hand.raised", keywords: ["camera", "microphone", "permissions", "firewall"]),
        .init(title: "Network", url: "x-apple.systempreferences:com.apple.Network-Settings.extension", symbol: "network", keywords: ["vpn", "dns", "ethernet"]),
        .init(title: "Users & Groups", url: "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension", symbol: "person.2", keywords: ["account", "login"]),
        .init(title: "Focus", url: "x-apple.systempreferences:com.apple.Focus-Settings.extension", symbol: "moon", keywords: ["do not disturb", "dnd"]),
    ]

    // MARK: Fuzzy matching (Raycast-style)

    private static let separators: Set<Character> = [" ", "-", "_", ".", "/", "("]

    /// Match score for `query` against `name`, higher is better; nil if no match.
    /// Rewards exact prefixes, initials/acronyms (vsc → Visual Studio Code),
    /// word-boundary and consecutive matches.
    static func fuzzyScore(_ query: String, _ name: String) -> Int? {
        let q = query.lowercased()
        let lower = name.lowercased()
        if lower.hasPrefix(q) { return 1000 - name.count }
        let initials = initials(of: name)
        if initials.hasPrefix(q) { return 850 - name.count }
        if initials.contains(q) { return 650 - name.count }
        if lower.contains(" " + q) { return 550 - name.count }
        if let r = lower.range(of: q) {
            return 450 - lower.distance(from: lower.startIndex, to: r.lowerBound) - name.count / 2
        }
        return subsequenceScore(q, lower, name)
    }

    /// First letters of each word and camelCase hump, e.g. "Visual Studio Code" -> "vsc".
    private static func initials(of s: String) -> String {
        var out = ""
        let chars = Array(s)
        var prevSep = true
        for (i, ch) in chars.enumerated() {
            let isSep = separators.contains(ch)
            let camel = ch.isUppercase && i > 0 && chars[i - 1].isLowercase
            if !isSep, prevSep || camel { out.append(Character(ch.lowercased())) }
            prevSep = isSep
        }
        return out
    }

    /// Ordered-subsequence match with word-boundary / consecutive bonuses.
    private static func subsequenceScore(_ q: String, _ lower: String, _ orig: String) -> Int? {
        let qa = Array(q), la = Array(lower), oa = Array(orig)
        var qi = 0, score = 100, prevMatch = -2, prevSep = true
        for ci in 0..<la.count {
            let ch = la[ci]
            if qi < qa.count, ch == qa[qi] {
                var bonus = 1
                if prevSep { bonus += 10 } else if oa[ci].isUppercase { bonus += 8 }
                if prevMatch == ci - 1 { bonus += 6 }
                score += bonus
                prevMatch = ci
                qi += 1
            }
            prevSep = separators.contains(ch)
        }
        return qi == qa.count ? score - orig.count / 3 : nil
    }

    @MainActor
    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    @MainActor
    @discardableResult
    func run(_ r: SearchResult) -> Bool {
        usage[r.id, default: 0] += 1
        defaults.set(usage, forKey: "startMenuUsage")
        switch r.action {
        case .openFile(let url):
            return NSWorkspace.shared.open(url)
        case .openFolder(let url):
            // Open in a NEW Finder window, frontmost, without pulling old ones up.
            osa("tell application \"Finder\"\nactivate\nmake new Finder window to (POSIX file \"\(url.path)\")\nend tell")
            return true
        case .settings(let s):
            if let url = URL(string: s) { NSWorkspace.shared.open(url) }
            return true
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return true
        }
    }

    @MainActor
    @discardableResult
    func runSelected() -> Bool {
        guard results.indices.contains(selection) else { return false }
        return run(results[selection])
    }
}

/// A tiny, exception-free arithmetic evaluator for the Start menu calculator.
enum Calc {
    static func eval(_ s: String) -> Double? {
        let allowed = Set("0123456789.+-*/()%^ ")
        guard s.allSatisfy({ allowed.contains($0) }),
              s.contains(where: { $0.isNumber }),
              s.contains(where: { "+-*/^%".contains($0) }) else { return nil }
        var p = Parser(Array(s.filter { !$0.isWhitespace }))
        guard let v = p.expr(), p.atEnd, v.isFinite else { return nil }
        return v
    }

    static func format(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 { return String(Int(v)) }
        return String(format: "%g", v)
    }

    private struct Parser {
        let c: [Character]; var i = 0
        init(_ c: [Character]) { self.c = c }
        var atEnd: Bool { i >= c.count }
        func peek() -> Character? { i < c.count ? c[i] : nil }

        mutating func expr() -> Double? {           // + -
            guard var left = term() else { return nil }
            while let op = peek(), op == "+" || op == "-" {
                i += 1
                guard let r = term() else { return nil }
                left = op == "+" ? left + r : left - r
            }
            return left
        }
        mutating func term() -> Double? {           // * / %
            guard var left = factor() else { return nil }
            while let op = peek(), op == "*" || op == "/" || op == "%" {
                i += 1
                guard let r = factor() else { return nil }
                if op == "*" { left *= r }
                else { if r == 0 { return nil }; left = op == "/" ? left / r : left.truncatingRemainder(dividingBy: r) }
            }
            return left
        }
        mutating func factor() -> Double? {         // unary, ^
            if peek() == "-" { i += 1; return factor().map { -$0 } }
            if peek() == "+" { i += 1; return factor() }
            guard var base = atom() else { return nil }
            if peek() == "^" { i += 1; guard let e = factor() else { return nil }; base = pow(base, e) }
            return base
        }
        mutating func atom() -> Double? {           // number or ( )
            if peek() == "(" {
                i += 1
                let v = expr()
                guard peek() == ")" else { return nil }
                i += 1
                return v
            }
            var num = ""
            while let ch = peek(), ch.isNumber || ch == "." { num.append(ch); i += 1 }
            return Double(num)
        }
    }
}

// MARK: - View

private struct StartMenuView: View {
    @ObservedObject var model: StartMenuModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search apps, files, settings…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .onSubmit { if model.runSelected() { model.onRequestClose?(false) } }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { idx, result in
                        StartRow(result: result, selected: idx == model.selection) {
                            if model.run(result) { model.onRequestClose?(false) }
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
        .glassPanel(14)
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
    let result: StartMenuModel.SearchResult
    let selected: Bool
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 10) {
                icon.frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.title).lineLimit(1)
                    if !result.subtitle.isEmpty {
                        Text(result.subtitle).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                if let tag = kindLabel {
                    Text(tag).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(selected ? 0.25 : 0)))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var icon: some View {
        if let img = result.icon {
            Image(nsImage: img).resizable().scaledToFit()
        } else if let sym = result.symbol {
            Image(systemName: sym).resizable().scaledToFit().padding(3)
                .foregroundStyle(.secondary)
        } else {
            Image(systemName: "doc").resizable().scaledToFit().foregroundStyle(.secondary)
        }
    }

    private var kindLabel: String? {
        switch result.kind {
        case .app:         return nil
        case .folder:      return "Folder"
        case .file:        return "File"
        case .setting:     return "Settings"
        case .calculation: return "="
        }
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
