import AppKit
import Carbon.HIToolbox

extension Notification.Name {
    static let recordingStateChanged = Notification.Name("macfixes.recordingStateChanged")
}

/// Screen recording: hotkey (or menu) picks an area, records it, and a second
/// press stops and saves an MP4 or GIF.
final class RecordingFeature: Feature, @unchecked Sendable {
    private let selector = AreaSelector()
    private let recorder = ScreenRecorder()
    private let overlay = RecordingOverlay()
    private var hotKeyIDs: [UInt32] = []
    private let defaults = UserDefaults.standard

    var isRecording: Bool { recorder.isRecording }

    // MARK: Settings

    var format: RecordingFormat {
        get { RecordingFormat(rawValue: defaults.string(forKey: "recFormat") ?? "") ?? .mp4 }
        set { defaults.set(newValue.rawValue, forKey: "recFormat") }
    }
    var fps: Int {
        get { let v = defaults.integer(forKey: "recFPS"); return v == 0 ? 30 : v }
        set { defaults.set(newValue, forKey: "recFPS") }
    }
    var showsCursor: Bool {
        get { defaults.object(forKey: "recCursor") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "recCursor") }
    }
    var saveDirectory: URL {
        if let p = defaults.string(forKey: "recDir") { return URL(fileURLWithPath: p) }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }
    func setSaveDirectory(_ url: URL) { defaults.set(url.path, forKey: "recDir") }

    static let defaultKeys = [
        KeyCombo(keyCode: UInt32(kVK_F13), modifiers: UInt32(shiftKey | controlKey)),
        KeyCombo(keyCode: UInt32(kVK_F12), modifiers: UInt32(shiftKey | controlKey)),
    ]
    var recordKeys: [KeyCombo] {
        get {
            if let data = defaults.data(forKey: "recKeys"),
               let a = try? JSONDecoder().decode([KeyCombo].self, from: data) { return a }
            return Self.defaultKeys
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: "recKeys") }
        }
    }

    // MARK: Feature lifecycle

    @discardableResult
    func start() -> Bool { registerHotKeys(); return true }
    func stop() { hotKeyIDs.forEach { HotKeyCenter.shared.unregister($0) }; hotKeyIDs = [] }
    func reloadHotKeys() { stop(); registerHotKeys() }

    private func registerHotKeys() {
        for combo in recordKeys {
            hotKeyIDs.append(HotKeyCenter.shared.register(combo) { [weak self] in self?.toggle() })
        }
    }

    // MARK: Recording flow

    /// Hotkey toggle: stop if recording, else record in the saved format.
    func toggle() {
        recorder.isRecording ? stopRecording() : record(format: format)
    }

    /// Start a recording in a specific format (used by the menu).
    func record(format: RecordingFormat) {
        guard !recorder.isRecording else { return }
        guard Permissions.hasScreenRecording else {
            Permissions.requestScreenRecording()
            Permissions.openSettings(.screenRecording)
            return
        }
        self.format = format
        let fps = self.fps, cursor = self.showsCursor, dir = self.saveDirectory
        selector.select { [weak self] rect in
            guard let self, let rect else { return }
            Task {
                do {
                    try await self.recorder.start(area: rect, format: format, fps: fps,
                                                  showsCursor: cursor, saveDir: dir)
                    await MainActor.run {
                        self.overlay.show(areaAX: rect,
                                          onStop: { self.stopRecording() },
                                          onCancel: { self.cancelRecording() })
                    }
                    NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
                } catch {
                    NSLog("recording failed to start: \(error)")
                }
            }
        }
    }

    func stopRecording() {
        Task {
            let url = await recorder.stop()
            await MainActor.run { self.overlay.hide() }
            NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
            if let url {
                await MainActor.run {
                    NSSound(named: "Glass")?.play()
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }

    func cancelRecording() {
        Task {
            await recorder.cancel()
            await MainActor.run { self.overlay.hide() }
            NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
        }
    }
}
