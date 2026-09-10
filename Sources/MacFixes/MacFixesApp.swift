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
        NotificationCenter.default.addObserver(forName: .keepAwakeChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusIcon() }
        }
    }

    private func updateStatusIcon() {
        let recording = features.capture.isRecording
        let awake = KeepAwake.shared.isActive
        let name = recording ? "record.circle" : awake ? "cup.and.saucer.fill" : "wrench.and.screwdriver"
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

        if features.capture.isRecording {
            let stop = NSMenuItem(title: "Stop recording", action: #selector(stopRecording), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
            let cancel = NSMenuItem(title: "Cancel recording", action: #selector(cancelRecording), keyEquivalent: "")
            cancel.target = self
            menu.addItem(cancel)
        } else {
            for action in allCaptureActions where features.capture.showInMenu(action) {
                let item = NSMenuItem(title: action.menuLabel, action: #selector(performCapture(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = action.id
                if let combo = features.capture.shortcut(for: action).first {
                    item.keyEquivalent = combo.appKitKeyEquivalent
                    item.keyEquivalentModifierMask = combo.appKitModifiers
                }
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        if features.clipboardEnabled {
            let clip = NSMenuItem(title: "Clipboard History…", action: #selector(openClipboard), keyEquivalent: "")
            clip.target = self
            clip.keyEquivalent = features.clipboard.hotKey.appKitKeyEquivalent
            clip.keyEquivalentModifierMask = features.clipboard.hotKey.appKitModifiers
            menu.addItem(clip)
        }

        let awake = KeepAwake.shared
        let awakeItem = NSMenuItem(title: awake.menuTitle, action: nil, keyEquivalent: "")
        awakeItem.image = NSImage(systemSymbolName: awake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer", accessibilityDescription: nil)
        let sub = NSMenu()
        let off = NSMenuItem(title: "Off", action: #selector(keepAwakeOff), keyEquivalent: "")
        off.target = self
        off.state = awake.isActive ? .off : .on
        sub.addItem(off)
        sub.addItem(.separator())
        for (idx, choice) in KeepAwake.durations.enumerated() {
            let item = NSMenuItem(title: choice.label, action: #selector(keepAwake(_:)), keyEquivalent: "")
            item.target = self
            item.tag = idx
            if awake.isActive, let active = awake.activeMinutes, active == choice.minutes { item.state = .on }
            sub.addItem(item)
        }
        awakeItem.submenu = sub
        menu.addItem(awakeItem)

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

    @objc private func performCapture(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let action = allCaptureActions.first(where: { $0.id == id }) else { return }
        features.capture.perform(action)
    }
    @objc private func stopRecording() { features.capture.stopRecording() }
    @objc private func openClipboard() { features.clipboard.showPanel() }
    @objc private func keepAwakeOff() { KeepAwake.shared.stop() }
    @objc private func keepAwake(_ sender: NSMenuItem) {
        guard KeepAwake.durations.indices.contains(sender.tag) else { return }
        KeepAwake.shared.start(minutes: KeepAwake.durations[sender.tag].minutes)
    }
    @objc private func cancelRecording() { features.capture.cancelRecording() }

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
