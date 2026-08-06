import SwiftUI
import AppKit

/// Central owner of the background feature modules. Source of truth for their
/// enabled state; persists to UserDefaults and starts/stops modules on toggle.
@MainActor
final class FeatureManager: ObservableObject {
    static let shared = FeatureManager()

    private let scroll = ScrollFeature()
    let screenshots = ScreenshotFeature()
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

    @Published var screenshotsEnabled: Bool {
        didSet {
            defaults.set(screenshotsEnabled, forKey: "screenshotsEnabled")
            apply(screenshots, enabled: screenshotsEnabled)
        }
    }

    private let defaults = UserDefaults.standard

    private init() {
        // First-launch defaults.
        if defaults.object(forKey: "scrollEnabled") == nil { defaults.set(true, forKey: "scrollEnabled") }
        if defaults.object(forKey: "invertMouse") == nil { defaults.set(true, forKey: "invertMouse") }
        if defaults.object(forKey: "screenshotsEnabled") == nil { defaults.set(true, forKey: "screenshotsEnabled") }

        // Initialise stored properties (didSet does not fire during init).
        scrollEnabled = defaults.bool(forKey: "scrollEnabled")
        invertMouse = defaults.bool(forKey: "invertMouse")
        screenshotsEnabled = defaults.bool(forKey: "screenshotsEnabled")

        scroll.invertMouse = invertMouse
    }

    /// Start whatever should be running at launch.
    func bootstrap() {
        if scrollEnabled { _ = scroll.start() }
        if screenshotsEnabled { screenshots.start() }
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
