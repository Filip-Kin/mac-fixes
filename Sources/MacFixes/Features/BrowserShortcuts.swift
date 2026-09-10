import AppKit
import Combine

/// Windows-style browser shortcuts, set up the way System Settings › Keyboard ›
/// Keyboard Shortcuts › App Shortcuts does it: an `NSUserKeyEquivalents`
/// dictionary in each browser's defaults, keyed by menu item title. AppKit
/// applies these when the menu is built, so no event tap is involved and the
/// browser handles the key itself.
///
/// Entries are merged into the dictionary (other user entries are left alone)
/// and only our own titles are removed on reset. Browsers pick the change up
/// on their next launch.
@MainActor
final class BrowserShortcuts: ObservableObject {
    struct Browser: Identifiable {
        let id: String            // bundle id
        let name: String
        /// Menu titles for each action; nil where the browser has no such
        /// menu item (nothing can be bound by title then).
        let reload: String?
        let hardReload: String?
        let reopenTab: String?
        /// True when the titles were checked against the app on a real Mac.
        let verified: Bool
    }

    /// F5 = U+F708 (NSF5FunctionKey). "^" control, "$" shift, "@" command, "~" option.
    private static let f5 = "\u{F708}"
    private static let reloadKey = f5
    private static let hardReloadKey = "^" + f5
    private static let reopenTabKey = "^$t"

    // Reopen-closed-tab is deliberately left out: Ctrl+Shift+T already reopens
    // a tab on both the built-in and external keyboards in every browser, so
    // there is nothing to bind. Only refresh / hard-refresh are set here.
    static let known: [Browser] = [
        // Edge's regular and force-refresh menu items share the title "Refresh
        // This Page", so only the plain F5 refresh can be bound by title.
        Browser(id: "com.microsoft.edgemac", name: "Microsoft Edge",
                reload: "Refresh This Page", hardReload: nil, reopenTab: nil, verified: true),
        Browser(id: "com.apple.Safari", name: "Safari",
                reload: "Reload Page", hardReload: "Reload Page From Origin",
                reopenTab: nil, verified: true),
        // Chromium titles; not verified on this Mac.
        Browser(id: "com.google.Chrome", name: "Google Chrome",
                reload: "Reload This Page", hardReload: "Force Reload This Page",
                reopenTab: nil, verified: false),
        Browser(id: "com.brave.Browser", name: "Brave",
                reload: "Reload This Page", hardReload: "Force Reload This Page",
                reopenTab: nil, verified: false),
    ]

    /// Browsers from `known` that are installed.
    var installed: [Browser] {
        Self.known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    }

    @Published private(set) var applied: Bool
    /// Bundle ids whose last write failed (Safari's container is protected
    /// unless the app has Full Disk Access).
    @Published private(set) var failedWrites: Set<String> = []

    private let defaults = UserDefaults.standard
    private let appliedKey = "browserShortcutsApplied"

    init() { applied = defaults.bool(forKey: "browserShortcutsApplied") }

    /// True when at least one installed browser could not be written (needs
    /// Full Disk Access). Only meaningful right after apply()/remove().
    var needsFullDiskAccess: Bool { !failedWrites.isEmpty }

    func name(for id: String) -> String { Self.known.first { $0.id == id }?.name ?? id }

    /// What a browser gets: (menu title, key equivalent) pairs.
    func entries(for b: Browser) -> [(title: String, key: String)] {
        var out: [(String, String)] = []
        if let t = b.reload { out.append((t, Self.reloadKey)) }
        if let t = b.hardReload { out.append((t, Self.hardReloadKey)) }
        if let t = b.reopenTab { out.append((t, Self.reopenTabKey)) }
        return out
    }

    func apply() {
        var failed: Set<String> = []
        for b in installed {
            var dict = Self.readEquivalents(b.id)
            for (title, key) in entries(for: b) { dict[title] = key }
            let ok = Self.writeEquivalents(b.id, dict)
            if !ok { failed.insert(b.id) }
            trace("BrowserShortcuts", "\(b.name): set \(entries(for: b).map { "\($0.title)=\(Self.describe($0.key))" }.joined(separator: ", ")) → \(ok ? "ok" : "WRITE FAILED (needs Full Disk Access)")")
        }
        failedWrites = failed
        applied = true
        defaults.set(true, forKey: appliedKey)
    }

    func remove() {
        var failed: Set<String> = []
        for b in installed {
            var dict = Self.readEquivalents(b.id)
            for (title, key) in entries(for: b) where dict[title] == key { dict[title] = nil }
            let ok = Self.writeEquivalents(b.id, dict)
            if !ok { failed.insert(b.id) }
            trace("BrowserShortcuts", "\(b.name): removed our entries → \(ok ? "ok" : "WRITE FAILED")")
        }
        failedWrites = failed
        applied = false
        defaults.set(false, forKey: appliedKey)
    }

    /// Human-readable key equivalent, e.g. "⌃⇧T", "F5".
    static func describe(_ key: String) -> String {
        var s = ""
        var rest = Substring(key)
        while let c = rest.first, "@~^$".contains(c) {
            switch c {
            case "^": s += "⌃"; case "~": s += "⌥"; case "$": s += "⇧"; default: s += "⌘"
            }
            rest = rest.dropFirst()
        }
        if rest == f5 { return s + "F5" }
        return s + rest.uppercased()
    }

    // MARK: defaults plumbing

    // `defaults` is used rather than CFPreferences because it follows sandboxed
    // apps (Safari) into their container the way System Settings does.

    private static func readEquivalents(_ bundleID: String) -> [String: String] {
        let out = run(["defaults", "export", bundleID, "-"]).data
        guard let data = out,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let dict = plist["NSUserKeyEquivalents"] as? [String: String] else { return [:] }
        return dict
    }

    @discardableResult
    private static func writeEquivalents(_ bundleID: String, _ dict: [String: String]) -> Bool {
        if dict.isEmpty {
            // Nothing left of ours; leave any pre-existing (empty) key as-is.
            return run(["defaults", "delete", bundleID, "NSUserKeyEquivalents"]).ok
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0),
              let xml = String(data: data, encoding: .utf8) else { return false }
        return run(["defaults", "write", bundleID, "NSUserKeyEquivalents", xml]).ok
    }

    private static func run(_ argv: [String]) -> (data: Data?, ok: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = argv
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { NSLog("defaults failed (\(argv)): \(error)"); return (nil, false) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (data, p.terminationStatus == 0)
    }
}
