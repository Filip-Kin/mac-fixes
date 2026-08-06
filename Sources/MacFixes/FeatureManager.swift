import SwiftUI
import AppKit

/// Central owner of the background feature modules. Source of truth for their
/// enabled state; persists to UserDefaults and starts/stops modules on toggle.
@MainActor
final class FeatureManager: ObservableObject {
    static let shared = FeatureManager()

    private let scroll = ScrollFeature()
    let capture = CaptureFeature()
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

    private let defaults = UserDefaults.standard

    private init() {
        // First-launch defaults.
        if defaults.object(forKey: "scrollEnabled") == nil { defaults.set(true, forKey: "scrollEnabled") }
        if defaults.object(forKey: "invertMouse") == nil { defaults.set(true, forKey: "invertMouse") }
        if defaults.object(forKey: "captureEnabled") == nil { defaults.set(true, forKey: "captureEnabled") }
        // Keyboard fixes are intrusive; default off until the user opts in.

        // Initialise stored properties (didSet does not fire during init).
        scrollEnabled = defaults.bool(forKey: "scrollEnabled")
        invertMouse = defaults.bool(forKey: "invertMouse")
        captureEnabled = defaults.bool(forKey: "captureEnabled")
        keyboardEnabled = defaults.bool(forKey: "keyboardEnabled")
        windowsEnabled = defaults.bool(forKey: "windowsEnabled")

        scroll.invertMouse = invertMouse
    }

    /// Start whatever should be running at launch.
    func bootstrap() {
        if scrollEnabled { _ = scroll.start() }
        if captureEnabled { _ = capture.start() }
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
