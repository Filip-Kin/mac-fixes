import SwiftUI
import AppKit
import ServiceManagement

/// Central owner of the background feature modules. Source of truth for their
/// enabled state; persists to UserDefaults and starts/stops modules on toggle.
@MainActor
final class FeatureManager: ObservableObject {
    static let shared = FeatureManager()

    private let scroll = ScrollFeature()
    let capture = CaptureFeature()
    let clipboard = ClipboardFeature()
    let keyboard = KeyboardFeature()
    let browserShortcuts = BrowserShortcuts()
    let windows = WindowFeature()
    let tweaks = SystemTweaks()
    let taskbar = TaskbarFeature()
    let startMenu = StartMenuFeature()
    let altTab = AltTabFeature()

    // MARK: Persisted feature state

    @Published var scrollEnabled: Bool {
        didSet {
            defaults.set(scrollEnabled, forKey: "scrollEnabled")
            apply(scroll, enabled: scrollEnabled)
        }
    }

    /// Whether the mouse wheel is inverted (trackpad always left natural).
    @Published var invertMouse: Bool {
        didSet {
            defaults.set(invertMouse, forKey: "invertMouse")
            scroll.invertMouse = invertMouse
        }
    }

    @Published var captureEnabled: Bool {
        didSet {
            defaults.set(captureEnabled, forKey: "captureEnabled")
            apply(capture, enabled: captureEnabled)
        }
    }

    @Published var clipboardEnabled: Bool {
        didSet {
            defaults.set(clipboardEnabled, forKey: "clipboardEnabled")
            apply(clipboard, enabled: clipboardEnabled)
        }
    }

    @Published var keyboardEnabled: Bool {
        didSet {
            defaults.set(keyboardEnabled, forKey: "keyboardEnabled")
            apply(keyboard, enabled: keyboardEnabled)
        }
    }

    @Published var windowsEnabled: Bool {
        didSet {
            defaults.set(windowsEnabled, forKey: "windowsEnabled")
            apply(windows, enabled: windowsEnabled)
        }
    }

    @Published var taskbarEnabled: Bool {
        didSet {
            defaults.set(taskbarEnabled, forKey: "taskbarEnabled")
            apply(taskbar, enabled: taskbarEnabled)
        }
    }

    @Published var startMenuEnabled: Bool {
        didSet {
            defaults.set(startMenuEnabled, forKey: "startMenuEnabled")
            apply(startMenu, enabled: startMenuEnabled)
        }
    }

    /// Taskbar on every monitor (vs. the primary only).
    @Published var taskbarAllScreens: Bool {
        didSet {
            defaults.set(taskbarAllScreens, forKey: "taskbarAllScreens")
            taskbar.placePanels()
        }
    }

    @Published var altTabEnabled: Bool {
        didSet {
            defaults.set(altTabEnabled, forKey: "altTabEnabled")
            apply(altTab, enabled: altTabEnabled)
        }
    }

    /// Hide the macOS Dock entirely (auto-hide with a very long reveal delay, so
    /// it never slides up). Pairs with the taskbar.
    @Published var hideDock: Bool {
        didSet {
            defaults.set(hideDock, forKey: "hideDock")
            DockControl.setHidden(hideDock)
        }
    }

    /// Registered as a login item (System Settings > General > Login Items).
    /// Defaults to on: the keyboard modifier swap for external keyboards is
    /// applied by the running app, so it needs to be up at login.
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: "launchAtLogin")
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("launch at login: \(error)")
            }
        }
    }

    private let defaults = UserDefaults.standard

    private init() {
        // First-launch defaults.
        if defaults.object(forKey: "scrollEnabled") == nil { defaults.set(true, forKey: "scrollEnabled") }
        if defaults.object(forKey: "invertMouse") == nil { defaults.set(true, forKey: "invertMouse") }
        if defaults.object(forKey: "captureEnabled") == nil { defaults.set(true, forKey: "captureEnabled") }
        if defaults.object(forKey: "clipboardEnabled") == nil { defaults.set(true, forKey: "clipboardEnabled") }
        // Keyboard fixes are intrusive; default off until the user opts in.

        // Initialise stored properties (didSet does not fire during init).
        scrollEnabled = defaults.bool(forKey: "scrollEnabled")
        invertMouse = defaults.bool(forKey: "invertMouse")
        captureEnabled = defaults.bool(forKey: "captureEnabled")
        clipboardEnabled = defaults.bool(forKey: "clipboardEnabled")
        keyboardEnabled = defaults.bool(forKey: "keyboardEnabled")
        windowsEnabled = defaults.bool(forKey: "windowsEnabled")
        taskbarEnabled = defaults.bool(forKey: "taskbarEnabled")
        startMenuEnabled = defaults.bool(forKey: "startMenuEnabled")
        taskbarAllScreens = defaults.bool(forKey: "taskbarAllScreens")
        altTabEnabled = defaults.bool(forKey: "altTabEnabled")
        hideDock = defaults.bool(forKey: "hideDock")
        launchAtLogin = SMAppService.mainApp.status == .enabled

        scroll.invertMouse = invertMouse
    }

    /// Start whatever should be running at launch.
    func bootstrap() {
        // The taskbar's Start button opens the Start menu.
        taskbar.setStartAction { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.startMenu.toggle() }
        }
        // First launch: register as a login item unless the user has opted out.
        if defaults.object(forKey: "launchAtLogin") == nil, !launchAtLogin { launchAtLogin = true }
        if scrollEnabled { _ = scroll.start() }
        if captureEnabled { _ = capture.start() }
        if clipboardEnabled { _ = clipboard.start() }
        if keyboardEnabled { _ = keyboard.start() }
        if windowsEnabled { _ = windows.start() }
        if taskbarEnabled { _ = taskbar.start() }
        if startMenuEnabled { _ = startMenu.start() }
        if altTabEnabled { _ = altTab.start() }
        if hideDock { DockControl.setHidden(true) }
        // Reapply the persistent modifier swap and start its hot-plug watcher,
        // even if the event-tap part of the keyboard feature is off.
        keyboard.modifierSwap.reapplyIfEnabled()
    }

    private func apply(_ feature: Feature, enabled: Bool) {
        if enabled { _ = feature.start() } else { feature.stop() }
    }
}

/// Hides or restores the macOS Dock via its `defaults`.
enum DockControl {
    static func setHidden(_ hidden: Bool) {
        if hidden {
            run(["/usr/bin/defaults", "write", "com.apple.dock", "autohide", "-bool", "true"])
            run(["/usr/bin/defaults", "write", "com.apple.dock", "autohide-delay", "-float", "1000"])
            run(["/usr/bin/defaults", "write", "com.apple.dock", "autohide-time-modifier", "-float", "0"])
        } else {
            run(["/usr/bin/defaults", "delete", "com.apple.dock", "autohide-delay"])
            run(["/usr/bin/defaults", "delete", "com.apple.dock", "autohide-time-modifier"])
            run(["/usr/bin/defaults", "write", "com.apple.dock", "autohide", "-bool", "false"])
        }
        run(["/usr/bin/killall", "Dock"])
    }

    private static func run(_ argv: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
    }
}

/// A background module that can be switched on and off.
protocol Feature: AnyObject {
    /// Returns false if it could not start (e.g. missing permission).
    @discardableResult func start() -> Bool
    func stop()
}
