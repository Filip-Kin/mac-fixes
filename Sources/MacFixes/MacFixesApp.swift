import SwiftUI
import AppKit

@main
struct MacFixesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var features = FeatureManager.shared

    var body: some Scene {
        MenuBarExtra("Filip's Mac Fixes", systemImage: "wrench.and.screwdriver") {
            MenuBarContent(features: features)
        }

        Window("Filip's Mac Fixes", id: "settings") {
            SettingsView(features: features)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 720, height: 480)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar only, no dock icon
        FeatureManager.shared.bootstrap()
    }
}
