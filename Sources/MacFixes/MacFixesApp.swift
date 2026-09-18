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
    private var activityToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar only, no dock icon
        // Stop App Nap from suspending our run loop — that silently kills the
        // global event taps (Alt-Tab, keyboard shortcuts) until the next event.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated],
            reason: "Global input event taps must keep receiving events")
        features.bootstrap()
        // Right-click empty taskbar space opens Settings on the Taskbar pane.
        features.taskbar.setOpenSettingsAction { [weak self] in
            MainActor.assumeIsolated { self?.showSettings(pane: .taskbar) }
        }
        setupStatusItem()
        NotificationCenter.default.addObserver(forName: .recordingStateChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusIcon() }
        }
        NotificationCenter.default.addObserver(forName: .keepAwakeChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusIcon() }
        }
        NotificationCenter.default.addObserver(forName: .openTaskManager, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.features.taskManager.open() }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // macfixes://taskmanager (from the standalone Task Manager.app launcher).
        if urls.contains(where: { $0.scheme == "macfixes" && ($0.host == "taskmanager" || $0.path.contains("taskmanager")) }) {
            features.taskManager.open()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Restore any OS settings we changed (e.g. the title-bar double-click
        // action) so quitting doesn't leave the system altered.
        features.windows.stop()
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

        if features.softwareVolumeEnabled {
            let item = NSMenuItem()
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 30))
            let icon = NSImageView(frame: NSRect(x: 12, y: 6, width: 18, height: 18))
            icon.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)
            icon.contentTintColor = .secondaryLabelColor
            let slider = NSSlider(value: Double(features.softwareVolume.currentVolume), minValue: 0, maxValue: 1,
                                  target: self, action: #selector(volumeSliderChanged(_:)))
            slider.frame = NSRect(x: 36, y: 4, width: 172, height: 22)
            container.addSubview(icon)
            container.addSubview(slider)
            item.view = container
            menu.addItem(item)
            menu.addItem(.separator())
        }

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
                applyShortcut(to: item, features.capture.shortcut(for: action).first)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        if features.clipboardEnabled {
            let clip = NSMenuItem(title: "Clipboard History…", action: #selector(openClipboard), keyEquivalent: "")
            clip.target = self
            applyShortcut(to: clip, features.clipboard.hotKey)
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

        let taskMgr = NSMenuItem(title: "Task Manager", action: #selector(openTaskManager), keyEquivalent: "")
        taskMgr.target = self
        menu.addItem(taskMgr)

        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit Filip's Mac Fixes",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quit)
    }

    /// A menu item whose shortcut is shown the native way (gray, right-aligned)
    /// via keyEquivalent. Status-menu key equivalents are display-only, so this
    /// does not double-fire with the global Carbon hotkey.
    private func addActionItem(_ menu: NSMenu, _ title: String,
                               shortcut: KeyCombo?, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        applyShortcut(to: item, shortcut)
        menu.addItem(item)
    }

    /// Shows a shortcut on a menu item. With the Windows-style swap on, the
    /// shortcut is drawn in Windows key names (e.g. "Win+V") via an attributed
    /// title: a right-aligned tab stop pushes it to the edge and greys it, to
    /// match the native look (NSMenuItem key equivalents can only render Mac
    /// glyphs). Off, it uses the native key equivalent. Either way it is display
    /// only: the shortcut fires via the global Carbon hotkey / event tap.
    private func applyShortcut(to item: NSMenuItem, _ combo: KeyCombo?) {
        guard let combo else { return }
        guard features.keyboard.swapModifiers else {
            item.keyEquivalent = combo.appKitKeyEquivalent
            item.keyEquivalentModifierMask = combo.appKitModifiers
            return
        }
        let shortcut = combo.display(windowsStyle: true)
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .right, location: 220)]
        let font = NSFont.menuFont(ofSize: 0)
        let attr = NSMutableAttributedString(
            string: "\(item.title)\t\(shortcut)",
            attributes: [.font: font, .paragraphStyle: para])
        let scStart = (item.title as NSString).length + 1   // +1 for the tab
        attr.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                          range: NSRange(location: scStart, length: (shortcut as NSString).length))
        item.attributedTitle = attr
    }

    // MARK: Actions

    @objc private func performCapture(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let action = allCaptureActions.first(where: { $0.id == id }) else { return }
        features.capture.perform(action)
    }
    @objc private func volumeSliderChanged(_ sender: NSSlider) {
        features.softwareVolume.setVolumeFromMenu(Float(sender.doubleValue))
    }
    @objc private func stopRecording() { features.capture.stopRecording() }
    @objc private func openClipboard() { features.clipboard.showPanel() }
    @objc private func keepAwakeOff() { KeepAwake.shared.stop() }
    @objc private func keepAwake(_ sender: NSMenuItem) {
        guard KeepAwake.durations.indices.contains(sender.tag) else { return }
        KeepAwake.shared.start(minutes: KeepAwake.durations[sender.tag].minutes)
    }
    @objc private func cancelRecording() { features.capture.cancelRecording() }

    @objc private func openTaskManager() { features.taskManager.open() }
    @objc private func openSettings() { showSettings() }

    /// Open Settings, optionally jumping to a specific pane.
    func showSettings(pane: SettingsPane? = nil) {
        if let pane { SettingsRouter.shared.pane = pane }
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
