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
    let windows = WindowFeature()
    let tweaks = SystemTweaks()

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
        launchAtLogin = SMAppService.mainApp.status == .enabled

        scroll.invertMouse = invertMouse
    }

    /// Start whatever should be running at launch.
    func bootstrap() {
        // First launch: register as a login item unless the user has opted out.
        if defaults.object(forKey: "launchAtLogin") == nil, !launchAtLogin { launchAtLogin = true }
        if scrollEnabled { _ = scroll.start() }
        if captureEnabled { _ = capture.start() }
        if clipboardEnabled { _ = clipboard.start() }
        if keyboardEnabled { _ = keyboard.start() }
        if windowsEnabled { _ = windows.start() }
        // Reapply the persistent modifier swap and start its hot-plug watcher,
        // even if the event-tap part of the keyboard feature is off.
        keyboard.modifierSwap.reapplyIfEnabled()
    }

    private func apply(_ feature: Feature, enabled: Bool) {
        if enabled { _ = feature.start() } else { feature.stop() }
    }
}

/// A background module that can be switched on and off.
protocol Feature: AnyObject {
    /// Returns false if it could not start (e.g. missing permission).
    @discardableResult func start() -> Bool
    func stop()
}
