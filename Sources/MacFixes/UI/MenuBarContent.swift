import SwiftUI
import AppKit

struct MenuBarContent: View {
    @ObservedObject var features: FeatureManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Area screenshot → clipboard\(hint(features.screenshots.areaToClipboardKeys))") {
            features.screenshots.areaToClipboard()
        }
        Button("Area screenshot → file\(hint(features.screenshots.areaToFileKeys))") {
            features.screenshots.areaToFile()
        }

        Divider()

        Toggle("Invert mouse wheel", isOn: $features.invertMouse)

        Divider()

        Button("Settings…") {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit Filip's Mac Fixes") { NSApp.terminate(nil) }
    }

    /// "  (⌃F13 / ⌃F12)" style hint appended to a menu item title.
    private func hint(_ combos: [KeyCombo]) -> String {
        guard !combos.isEmpty else { return "" }
        return "  (" + combos.map(\.display).joined(separator: " / ") + ")"
    }
}
