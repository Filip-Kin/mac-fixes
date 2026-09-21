import AppKit
import SwiftUI
import Carbon.HIToolbox
import ScreenCaptureKit

/// A Windows-style Alt-Tab switcher. Hold Option (the physical Alt on a PC
/// keyboard) and tap Tab to cycle through every open window as thumbnails;
/// release Option to switch to the highlighted one. Shift reverses; Esc cancels.
///
/// Driven by an event tap so it can swallow Option+Tab and detect the Option
/// release. The tap and overlay live on the main run loop.
final class AltTabFeature: Feature, @unchecked Sendable {
    private var tap: CFMachPort?
    private var panel: AltTabPanel?
    private let model = AltTabModel()
    private var shown = false                 // written on main, read on tap thread (Bool, atomic enough)
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?

    @discardableResult
    func start() -> Bool {
        guard tapThread == nil else { return true }
        // The panel and commit callback live on the main actor.
        MainActor.assumeIsolated {
            panel = AltTabPanel(model: model)
            model.onCommit = { [weak self] in MainActor.assumeIsolated { self?.commit() } }
        }
        // Run the event tap on its own thread with its own run loop. Building the
        // switcher and grabbing thumbnails happen on main; if that work stalls
        // the main run loop, event delivery here is unaffected, so the tap never
        // gets disabled for being slow — the recurring "Alt-Tab stopped" cause.
        let thread = Thread { [weak self] in
            guard let self else { return }
            let mask = CGEventMask(
                (1 << CGEventType.keyDown.rawValue) |
                (1 << CGEventType.keyUp.rawValue) |
                (1 << CGEventType.flagsChanged.rawValue))
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                            place: .headInsertEventTap,
                                            options: .defaultTap,
                                            eventsOfInterest: mask,
                                            callback: altTabCallback,
                                            userInfo: refcon) else {
                trace("AltTab", "tap create failed (accessibility not granted?)")
                DispatchQueue.main.async { Permissions.promptAccessibility() }
                return
            }
            self.tap = t
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
            self.tapRunLoop = CFRunLoopGetCurrent()
            // Watchdog on this same run loop: re-enable if macOS ever disables it.
            let w = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
                guard let self, let t = self.tap else { return }
                if !CGEvent.tapIsEnabled(tap: t) {
                    CGEvent.tapEnable(tap: t, enable: true)
                    trace("AltTab", "watchdog re-enabled tap")
                }
            }
            RunLoop.current.add(w, forMode: .common)
            trace("AltTab", "tap running on dedicated thread")
            CFRunLoopRun()
            trace("AltTab", "tap run loop exited")
        }
        thread.name = "com.filipkin.macfixes.alttab"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
        return true
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t); tap = nil }
        if let rl = tapRunLoop { CFRunLoopStop(rl); tapRunLoop = nil }
        tapThread = nil
        MainActor.assumeIsolated { cancel(); panel = nil }
    }

    fileprivate func reenable() { if let t = tap { CGEvent.tapEnable(tap: t, enable: true) } }

    /// Runs on the tap thread. Returns true to swallow the event; all UI work is
    /// dispatched to the main actor.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .flagsChanged:
            if shown, !event.flags.contains(.maskAlternate) {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.commit() } }
            }
            return false
        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == Int64(kVK_Tab) {
                let f = event.flags
                // Only log modifier+Tab (a switch attempt), not plain Tab typing.
                if f.contains(.maskAlternate) || f.contains(.maskCommand) || f.contains(.maskControl) {
                    trace("AltTab", "Tab down flags=0x\(String(f.rawValue, radix: 16)) alt=\(f.contains(.maskAlternate)) cmd=\(f.contains(.maskCommand)) ctrl=\(f.contains(.maskControl))")
                }
            }
            if code == Int64(kVK_Tab), event.flags.contains(.maskAlternate) {
                let shift = event.flags.contains(.maskShift)
                DispatchQueue.main.async { MainActor.assumeIsolated { self.onTab(shift: shift) } }
                return true
            }
            if code == Int64(kVK_Escape), shown {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.cancel() } }
                return true
            }
            return false
        case .keyUp:
            if shown, event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Tab) { return true }
            return false
        default:
            return false
        }
    }

    @MainActor private func onTab(shift: Bool) {
        if shown { model.advance(shift ? -1 : 1) } else { showOverlay() }
    }

    @MainActor private func showOverlay() {
        model.build()
        trace("AltTab", "showOverlay windows=\(model.windows.count)")
        let cursor = NSEvent.mouseLocation
        guard !model.windows.isEmpty, let panel,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) })
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
        shown = true
        trace("AltTab", "panel ordered front vis=\(panel.isVisible) level=\(panel.level.rawValue) frame=\(NSStringFromRect(panel.frame))")
    }

    @MainActor private func commit() {
        guard shown else { return }
        shown = false
        panel?.orderOut(nil)
        if let w = model.selected() {
            trace("AltTab", "commit raise \"\(w.title)\" pid=\(w.pid)")
            AXWindow.raise(w.element, pid: w.pid)
        } else {
            trace("AltTab", "commit no selection")
        }
        model.clear()
    }

    @MainActor private func cancel() {
        shown = false
        panel?.orderOut(nil)
        model.clear()
    }
}

private func altTabCallback(proxy: CGEventTapProxy, type: CGEventType,
                            event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let me = Unmanaged<AltTabFeature>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        me.reenable()
        return Unmanaged.passUnretained(event)
    }
    if me.handle(type: type, event: event) { return nil }
    return Unmanaged.passUnretained(event)
}

// MARK: - Model

final class AltTabModel: ObservableObject, @unchecked Sendable {
    struct Win: Identifiable {
        let id: CGWindowID
        let title: String
        let appName: String
        let appIcon: NSImage?
        let element: AXUIElement
        let pid: pid_t
    }

    @Published private(set) var windows: [Win] = []
    @Published var selection = 0
    @Published private(set) var thumbnails: [CGWindowID: NSImage] = [:]
    var onCommit: (() -> Void)?

    private var thumbCache: [CGWindowID: NSImage] = [:]

    @MainActor
    func build() {
        var nameByPid: [pid_t: String] = [:]
        var iconByPid: [pid_t: NSImage?] = [:]
        var axByPid: [pid_t: [CGWindowID: AXUIElement]] = [:]
        var list: [Win] = []
        for w in AXWindow.allWindows() {
            guard let app = NSRunningApplication(processIdentifier: w.pid),
                  app.activationPolicy == .regular else { continue }
            if axByPid[w.pid] == nil { axByPid[w.pid] = AXWindow.axWindowsByID(pid: w.pid) }
            // Exact per-window element when available; fall back to frame match so
            // the switcher never comes up empty if the private call misses.
            guard let el = axByPid[w.pid]?[w.id] ?? AXWindow.element(pid: w.pid, matchingFrame: w.frame) else { continue }
            if nameByPid[w.pid] == nil {
                nameByPid[w.pid] = app.localizedName ?? "App"
                iconByPid[w.pid] = app.icon
            }
            let name = nameByPid[w.pid] ?? "App"
            list.append(Win(id: w.id, title: w.title.isEmpty ? name : w.title,
                            appName: name, appIcon: iconByPid[w.pid] ?? nil, element: el, pid: w.pid))
        }
        windows = list
        var seeded: [CGWindowID: NSImage] = [:]
        for w in list { if let img = thumbCache[w.id] { seeded[w.id] = img } }
        thumbnails = seeded
        selection = list.count > 1 ? 1 : 0     // start on the previous window
        captureAll(list.map { $0.id })
    }

    @MainActor
    private func captureAll(_ ids: [CGWindowID]) {
        guard !ids.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
            for id in ids {
                guard let self, !self.windows.isEmpty else { return }
                guard let win = content.windows.first(where: { $0.windowID == id }) else { continue }
                let cfg = SCStreamConfiguration()
                cfg.width = max(1, Int(win.frame.width / 2))
                cfg.height = max(1, Int(win.frame.height / 2))
                cfg.showsCursor = false
                if let cg = try? await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: win), configuration: cfg) {
                    let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    self.thumbCache[id] = img
                    if self.thumbCache.count > 80 { self.thumbCache = [id: img] }
                    self.thumbnails[id] = img
                }
            }
        }
    }

    @MainActor func advance(_ delta: Int) {
        guard !windows.isEmpty else { return }
        selection = (selection + delta + windows.count) % windows.count
    }

    @MainActor func selected() -> Win? { windows.indices.contains(selection) ? windows[selection] : nil }

    @MainActor func clear() { windows = []; thumbnails = [:]; selection = 0 }
}

// MARK: - View

private struct AltTabRoot: View {
    @ObservedObject var model: AltTabModel
    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            AltTabView(model: model)
        }
    }
}

private struct AltTabView: View {
    @ObservedObject var model: AltTabModel

    /// Balanced grid like Windows: a near-square number of columns, each row
    /// centered (so 5 windows lay out as a centered 3 + 2).
    private var columns: Int {
        min(6, max(1, Int(ceil(Double(model.windows.count).squareRoot()))))
    }

    private var rows: [[Int]] {
        let cols = columns
        var out: [[Int]] = []
        var i = 0
        while i < model.windows.count {
            out.append(Array(i..<Swift.min(i + cols, model.windows.count)))
            i += cols
        }
        return out
    }

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 16) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 16) {
                        ForEach(row, id: \.self) { idx in
                            AltTabCard(win: model.windows[idx],
                                       thumb: model.thumbnails[model.windows[idx].id],
                                       selected: idx == model.selection)
                                .frame(width: 200)
                                .onTapGesture { model.selection = idx; model.onCommit?() }
                        }
                    }
                }
            }
            .padding(20)
            if model.windows.indices.contains(model.selection) {
                Text(model.windows[model.selection].title)
                    .font(.headline).lineLimit(1).padding(.bottom, 10)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .glassPanel(20)
        .padding(40)
    }
}

private struct AltTabCard: View {
    let win: AltTabModel.Win
    let thumb: NSImage?
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08))
                if let thumb {
                    Image(nsImage: thumb).resizable().scaledToFit()
                } else if let icon = win.appIcon {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 46, height: 46)
                }
            }
            .frame(height: 118)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? Color.accentColor : Color.primary.opacity(0.12),
                        lineWidth: selected ? 3 : 1))
            HStack(spacing: 5) {
                if let icon = win.appIcon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text(win.title).font(.caption).lineLimit(1)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(selected ? Color.accentColor.opacity(0.15) : Color.clear))
    }
}

// MARK: - Panel

final class AltTabPanel: NSPanel {
    init(model: AltTabModel) {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .popUpMenu
        isFloatingPanel = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingView(rootView: AltTabRoot(model: model))
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    override var canBecomeKey: Bool { false }
}
