import SwiftUI
import AppKit

struct MenuBarContent: View {
    @ObservedObject var features: FeatureManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Area screenshot → clipboard") { features.screenshots.areaToClipboard() }
        Button("Area screenshot → file") { features.screenshots.areaToFile() }

        Divider()

        Toggle("Invert mouse wheel", isOn: $features.invertMouse)

        Divider()

        Button("Settings…") {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit Filip's Mac Fixes") { NSApp.terminate(nil) }
    }
}
