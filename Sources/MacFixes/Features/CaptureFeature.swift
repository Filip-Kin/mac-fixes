import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

extension Notification.Name {
    static let recordingStateChanged = Notification.Name("macfixes.recordingStateChanged")
}

enum CaptureTarget: String, CaseIterable, Identifiable {
    case area, window, screen
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// One cell of the Area/Window/Screen × Shot/Record × MP4/GIF matrix.
struct CaptureAction: Identifiable, Hashable {
    let target: CaptureTarget
    let isRecord: Bool
    let format: RecordingFormat?   // nil for a screenshot

    var id: String { "\(target.rawValue).\(isRecord ? "rec" : "shot").\(format?.rawValue ?? "")" }
    var rowLabel: String {
        guard isRecord else { return "Screenshot" }
        return format == .gif ? "Record GIF" : "Record MP4"
    }
    var menuLabel: String {
        let what = isRecord ? (format == .gif ? "GIF" : "MP4") : "Screenshot"
        return "\(target.label) → \(what)"
    }
}

/// All nine actions (screenshot + MP4 + GIF for each target).
let allCaptureActions: [CaptureAction] = CaptureTarget.allCases.flatMap { t in
    [CaptureAction(target: t, isRecord: false, format: nil),
     CaptureAction(target: t, isRecord: true, format: .mp4),
     CaptureAction(target: t, isRecord: true, format: .gif)]
}

/// Screenshots and screen recording, unified. Each action can have its own
/// shortcut and menu visibility; two global switches (save to file, copy to
/// clipboard) apply to every capture.
final class CaptureFeature: Feature, @unchecked Sendable {
    private let selector = AreaSelector()
    private let recorder = ScreenRecorder()

    /// The stock screenshot camera-shutter sound.
    private lazy var shutter: NSSound? =
        NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
                byReference: true) ?? NSSound(named: "Grab")
    private func playShutter() { shutter?.stop(); shutter?.play() }
    private let overlay = RecordingOverlay()
    private var hotKeyIDs: [UInt32] = []
    private let d = UserDefaults.standard

    var isRecording: Bool { recorder.isRecording }

    // MARK: Global settings

    var saveToFile: Bool { get { d.object(forKey: "capSaveFile") as? Bool ?? true } set { d.set(newValue, forKey: "capSaveFile") } }
    var copyToClipboard: Bool { get { d.object(forKey: "capClipboard") as? Bool ?? true } set { d.set(newValue, forKey: "capClipboard") } }
    var showCursor: Bool { get { d.object(forKey: "capCursor") as? Bool ?? true } set { d.set(newValue, forKey: "capCursor") } }
    var fps: Int { get { let v = d.integer(forKey: "capFPS"); return v == 0 ? 30 : v } set { d.set(newValue, forKey: "capFPS") } }

    var saveLocation: URL {
        if let p = d.string(forKey: "capDir") { return URL(fileURLWithPath: p) }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return docs.appendingPathComponent("Mac Fixes")
    }
    func setSaveLocation(_ url: URL) { d.set(url.path, forKey: "capDir") }

    // MARK: Per-action config

    func shortcut(for a: CaptureAction) -> [KeyCombo] {
        if let data = d.data(forKey: "cap.\(a.id).keys"),
           let combos = try? JSONDecoder().decode([KeyCombo].self, from: data) { return combos }
        return Self.defaultShortcut(a)
    }
    func setShortcut(_ combos: [KeyCombo], for a: CaptureAction) {
        if let data = try? JSONEncoder().encode(combos) { d.set(data, forKey: "cap.\(a.id).keys") }
    }
    func showInMenu(_ a: CaptureAction) -> Bool {
        d.object(forKey: "cap.\(a.id).menu") as? Bool ?? Self.defaultShowInMenu(a)
    }
    func setShowInMenu(_ v: Bool, for a: CaptureAction) { d.set(v, forKey: "cap.\(a.id).menu") }

    private static func defaultShortcut(_ a: CaptureAction) -> [KeyCombo] {
        if a.target == .area, !a.isRecord {
            return [KeyCombo(keyCode: UInt32(kVK_F13), modifiers: UInt32(cmdKey)),
                    KeyCombo(keyCode: UInt32(kVK_F12), modifiers: UInt32(cmdKey))]
        }
        if a.target == .area, a.isRecord, a.format == .mp4 {
            return [KeyCombo(keyCode: UInt32(kVK_F13), modifiers: UInt32(shiftKey | controlKey)),
                    KeyCombo(keyCode: UInt32(kVK_F12), modifiers: UInt32(shiftKey | controlKey))]
        }
        return []
    }
    private static func defaultShowInMenu(_ a: CaptureAction) -> Bool {
        switch a.target {
        case .area: return true
        case .window, .screen: return !a.isRecord   // shots yes, records off by default
        }
    }

    // MARK: Feature lifecycle

    @discardableResult
    func start() -> Bool { registerHotKeys(); return true }
    func stop() { hotKeyIDs.forEach { HotKeyCenter.shared.unregister($0) }; hotKeyIDs = [] }
    func reloadHotKeys() { stop(); registerHotKeys() }

    private func registerHotKeys() {
        for a in allCaptureActions {
            for combo in shortcut(for: a) {
                hotKeyIDs.append(HotKeyCenter.shared.register(combo) { [weak self] in self?.perform(a) })
            }
        }
    }

    // MARK: Perform

    func perform(_ a: CaptureAction) {
        if a.isRecord {
            if recorder.isRecording { stopRecording(); return }
            performRecord(a.target, a.format ?? .mp4)
        } else {
            performShot(a.target)
        }
    }

    // MARK: Screenshots (screencapture)

    private func performShot(_ target: CaptureTarget) {
        let url = destURL(prefix: "Screenshot", ext: "png")
        switch target {
        case .area:
            // Freeze the screen at trigger time, then let the user pick a region
            // against that snapshot (snaps to windows/panes, ShareX-style). The
            // result is cropped from the frozen bitmap, so it captures the moment
            // the tool was invoked, not whatever changed during selection.
            guard Permissions.hasScreenRecording else {
                Permissions.requestScreenRecording()
                Permissions.openSettings(.screenRecording)
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let images = await self.captureAllDisplays()
                self.selector.selectFrozen(images: images) { cg in
                    guard let cg else { return }
                    self.saveCGImage(cg, to: url)
                }
            }
        case .window:
            runScreencapture(["-iw", "-o"], url: url)
        case .screen:
            // Capture the screen holding the focused window (not always main).
            let r = AXWindow.axFullFrame(AXWindow.focusedScreen())
            runScreencapture(rectArgs(r), url: url)
        }
    }

    /// `screencapture -R x,y,w,h <path>` — rect in AX (top-left) coordinates.
    private func rectArgs(_ r: CGRect) -> [String] {
        ["-R\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))"]
    }

    /// A full-resolution snapshot of every display, keyed by display id.
    @MainActor
    private func captureAllDisplays() async -> [CGDirectDisplayID: CGImage] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return [:] }
        var out: [CGDirectDisplayID: CGImage] = [:]
        for display in content.displays {
            let scale = NSScreen.screens.first { $0.displayID == display.displayID }?.backingScaleFactor ?? 2
            let cfg = SCStreamConfiguration()
            cfg.width = Int(CGFloat(display.width) * scale)
            cfg.height = Int(CGFloat(display.height) * scale)
            cfg.showsCursor = false
            let filter = SCContentFilter(display: display, excludingWindows: [])
            if let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) {
                out[display.displayID] = cg
            }
        }
        return out
    }

    private func saveCGImage(_ cg: CGImage, to url: URL) {
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: url)
            playShutter()   // area capture is silent (SCK); window/screen use screencapture's own sound
            handleOutput(url, isImage: true)
        } catch { NSLog("save screenshot failed: \(error)") }
    }

    private func runScreencapture(_ args: [String], url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = args + [url.path]
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                self?.handleOutput(url, isImage: true)
            }
        }
        try? p.run()
    }

    // MARK: Recording

    private func performRecord(_ target: CaptureTarget, _ format: RecordingFormat) {
        guard Permissions.hasScreenRecording else {
            Permissions.requestScreenRecording()
            Permissions.openSettings(.screenRecording)
            return
        }
        switch target {
        case .area:
            selector.select { [weak self] rect in
                guard let self, let rect else { return }
                self.beginRecord(rect, format)
            }
        case .screen:
            beginRecord(fullDisplayAX(), format)
        case .window:
            guard let win = AXWindow.frontmostWindow(), let f = AXWindow.frame(of: win) else { return }
            beginRecord(f, format)
        }
    }

    private func beginRecord(_ areaAX: CGRect, _ format: RecordingFormat) {
        let dir = destURLDir()
        let fps = self.fps, cursor = self.showCursor
        Task {
            do {
                try await recorder.start(area: areaAX, format: format, fps: fps,
                                         showsCursor: cursor, saveDir: dir)
                await MainActor.run {
                    self.overlay.show(areaAX: areaAX,
                                      onStop: { self.stopRecording() },
                                      onCancel: { self.cancelRecording() })
                }
                NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
            } catch {
                NSLog("recording failed to start: \(error)")
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
                    self.playShutter()
                    self.handleOutput(url, isImage: false)
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

    // MARK: Output routing

    private func handleOutput(_ url: URL, isImage: Bool) {
        guard copyToClipboard else { return }   // file already lives at `url`
        let pb = NSPasteboard.general
        pb.clearContents()
        if isImage, let img = NSImage(contentsOf: url) {
            pb.writeObjects([img, url as NSURL])   // image for pasting, file for attaching
        } else {
            pb.writeObjects([url as NSURL])
        }
    }

    // MARK: Destination

    private func destURLDir() -> URL {
        let dir = saveToFile ? saveLocation : URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func destURL(prefix: String, ext: String) -> URL {
        destURLDir().appendingPathComponent("\(prefix) \(Self.timestamp()).\(ext)")
    }

    private func fullDisplayAX() -> CGRect {
        AXWindow.axFullFrame(AXWindow.focusedScreen())
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: Date())
    }
}
