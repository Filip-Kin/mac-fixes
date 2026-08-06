import SwiftUI
import AppKit

@main
struct MacFixesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The real settings window is an AppKit NSWindow managed by the
        // delegate (reliable for a menu-bar-only app); this scene is a
        // placeholder to satisfy the App protocol.
        Settings { EmptyView() }
    }
}

/// Owns the menu-bar status item (AppKit, so shortcuts render natively) and
/// starts the feature modules.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var features: FeatureManager { .shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar only, no dock icon
        features.bootstrap()
        setupStatusItem()
        NotificationCenter.default.addObserver(forName: .recordingStateChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusIcon() }
        }
    }

    private func updateStatusIcon() {
        let recording = features.recording.isRecording
        let name = recording ? "record.circle" : "wrench.and.screwdriver"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Filip's Mac Fixes")
        if recording {
            image?.isTemplate = false
            statusItem.button?.contentTintColor = .systemRed
        } else {
            statusItem.button?.contentTintColor = nil
        }
        statusItem.button?.image = image
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "wrench.and.screwdriver",
                                           accessibilityDescription: "Filip's Mac Fixes")
        let menu = NSMenu()
        menu.delegate = self          // menuNeedsUpdate rebuilds it fresh each open
        statusItem.menu = menu
    }

    // Rebuild on every open so shortcut hints and the toggle state stay current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        addActionItem(menu, "Area screenshot → clipboard",
                      shortcut: features.screenshots.areaToClipboardKeys.first,
                      action: #selector(shotClipboard))
        addActionItem(menu, "Area screenshot → file",
                      shortcut: features.screenshots.areaToFileKeys.first,
                      action: #selector(shotFile))

        menu.addItem(.separator())

        let recording = features.recording.isRecording
        addActionItem(menu, recording ? "Stop recording" : "Record area…",
                      shortcut: recording ? nil : features.recording.recordKeys.first,
                      action: #selector(toggleRecording))

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit Filip's Mac Fixes",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    /// A menu item whose shortcut is shown the native way (gray, right-aligned)
    /// via keyEquivalent. Status-menu key equivalents are display-only, so this
    /// does not double-fire with the global Carbon hotkey.
    private func addActionItem(_ menu: NSMenu, _ title: String,
                               shortcut: KeyCombo?, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let shortcut {
            item.keyEquivalent = shortcut.appKitKeyEquivalent
            item.keyEquivalentModifierMask = shortcut.appKitModifiers
        }
        menu.addItem(item)
    }

    // MARK: Actions

    @objc private func shotClipboard() { features.screenshots.areaToClipboard() }
    @objc private func shotFile() { features.screenshots.areaToFile() }
    @objc private func toggleRecording() { features.recording.toggle() }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(features: features))
            let window = NSWindow(contentViewController: host)
            window.title = "Filip's Mac Fixes"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 720, height: 480))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
