import AppKit
import Carbon.HIToolbox

/// Screenshots via the built-in /usr/sbin/screencapture, behind global hotkeys
/// and menu items. Area select to clipboard or file, window capture.
final class ScreenshotFeature: Feature {
    private let tool = "/usr/sbin/screencapture"
    private var hotKeyIDs: [UInt32] = []
    private let defaults = UserDefaults.standard

    // MARK: Options (persisted)

    /// PNG or JPG.
    var fileType: String {
        get { defaults.string(forKey: "shotFileType") ?? "png" }
        set { defaults.set(newValue, forKey: "shotFileType") }
    }

    /// Play the shutter sound.
    var playSound: Bool {
        get { defaults.object(forKey: "shotSound") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "shotSound") }
    }

    /// Where file captures are saved.
    var saveDirectory: URL {
        if let path = defaults.string(forKey: "shotDir") { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }
    func setSaveDirectory(_ url: URL) { defaults.set(url.path, forKey: "shotDir") }

    // MARK: Hotkeys (persisted, with defaults)

    static let defaultAreaToClipboard = KeyCombo(keyCode: UInt32(kVK_ANSI_4),
                                                 modifiers: UInt32(cmdKey | controlKey))
    static let defaultAreaToFile = KeyCombo(keyCode: UInt32(kVK_ANSI_5),
                                            modifiers: UInt32(cmdKey | controlKey))

    var areaToClipboardKey: KeyCombo {
        get { load("keyAreaClipboard") ?? Self.defaultAreaToClipboard }
        set { save(newValue, "keyAreaClipboard") }
    }
    var areaToFileKey: KeyCombo {
        get { load("keyAreaFile") ?? Self.defaultAreaToFile }
        set { save(newValue, "keyAreaFile") }
    }

    // MARK: Feature lifecycle

    @discardableResult
    func start() -> Bool {
        registerHotKeys()
        return true
    }

    func stop() {
        hotKeyIDs.forEach { HotKeyCenter.shared.unregister($0) }
        hotKeyIDs = []
    }

    /// Call after changing a hotkey to re-bind.
    func reloadHotKeys() {
        stop()
        registerHotKeys()
    }

    private func registerHotKeys() {
        hotKeyIDs.append(HotKeyCenter.shared.register(areaToClipboardKey) { [weak self] in
            self?.areaToClipboard()
        })
        hotKeyIDs.append(HotKeyCenter.shared.register(areaToFileKey) { [weak self] in
            self?.areaToFile()
        })
    }

    // MARK: Actions

    func areaToClipboard() {
        run(["-i", "-c"] + commonFlags)
    }

    func areaToFile() {
        let name = "Screenshot \(Self.timestamp()).\(fileType)"
        let dest = saveDirectory.appendingPathComponent(name)
        run(["-i", "-t", fileType] + commonFlags + [dest.path])
    }

    func windowToClipboard() {
        // -W window mode, -o no shadow.
        run(["-i", "-W", "-o", "-c"] + commonFlags)
    }

    private var commonFlags: [String] {
        playSound ? [] : ["-x"]
    }

    private func run(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        do { try p.run() } catch { NSLog("screencapture failed: \(error)") }
    }

    // MARK: Persistence helpers

    private func load(_ key: String) -> KeyCombo? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }
    private func save(_ combo: KeyCombo, _ key: String) {
        if let data = try? JSONEncoder().encode(combo) { defaults.set(data, forKey: key) }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: Date())
    }
}
