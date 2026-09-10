import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case scroll = "Scroll"
    case capture = "Screen Capture"
    case clipboard = "Clipboard"
    case keyboard = "Keyboard"
    case windows = "Windows"
    case tweaks = "System Tweaks"
    case permissions = "Permissions"
    case about = "About"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .scroll: return "computermouse"
        case .capture: return "camera.viewfinder"
        case .clipboard: return "doc.on.clipboard"
        case .keyboard: return "keyboard"
        case .windows: return "macwindow"
        case .tweaks: return "slider.horizontal.3"
        case .permissions: return "lock.shield"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var features: FeatureManager
    @State private var pane: SettingsPane? = .scroll

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            ScrollView {
                Group {
                    switch pane ?? .scroll {
                    case .scroll: ScrollPane(features: features)
                    case .capture: CapturePane(features: features)
                    case .clipboard: ClipboardPane(features: features, clip: features.clipboard)
                    case .keyboard: KeyboardPane(features: features, swap: features.keyboard.modifierSwap, browsers: features.browserShortcuts)
                    case .windows: WindowsPane(features: features)
                    case .tweaks: TweaksPane(tweaks: features.tweaks)
                    case .permissions: PermissionsPane()
                    case .about: AboutPane(features: features)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Panes

private struct ScrollPane: View {
    @ObservedObject var features: FeatureManager
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader("Scroll", "Per-device scroll direction.")
            Toggle("Enable scroll fix", isOn: $features.scrollEnabled)
            Toggle("Invert mouse wheel (trackpad stays natural)", isOn: $features.invertMouse)
                .disabled(!features.scrollEnabled)
            Text("Keep macOS ‘natural scrolling’ ON in System Settings. This inverts only physical mouse wheels, detected as non-continuous scroll events.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct CapturePane: View {
    @ObservedObject var features: FeatureManager
    @State private var refresh = false

    var body: some View {
        let cap = features.capture
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader("Screen Capture", "Screenshots and recording. Each combination can have its own shortcut and menu item.")
            Toggle("Enable capture shortcuts", isOn: $features.captureEnabled)

            HStack(spacing: 24) {
                Toggle("Save to file", isOn: Binding(
                    get: { cap.saveToFile }, set: { cap.saveToFile = $0; refresh.toggle() }))
                Toggle("Copy to clipboard", isOn: Binding(
                    get: { cap.copyToClipboard }, set: { cap.copyToClipboard = $0; refresh.toggle() }))
            }
            Text("Both apply to every capture. With ‘save to file’ off, captures go to a temp folder so they can still be copied to the clipboard.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text("Save to: \(cap.saveLocation.path)").font(.callout).foregroundStyle(.secondary)
                Button("Change…") { chooseFolder(cap) }
            }
            HStack(spacing: 24) {
                Stepper("Recording: \(cap.fps) fps", value: Binding(
                    get: { cap.fps }, set: { cap.fps = $0; refresh.toggle() }), in: 10...60, step: 5)
                    .frame(width: 200)
                Toggle("Show cursor", isOn: Binding(
                    get: { cap.showCursor }, set: { cap.showCursor = $0; refresh.toggle() }))
            }

            Divider()

            ForEach(CaptureTarget.allCases) { target in
                Text(target.label).font(.headline)
                ForEach(allCaptureActions.filter { $0.target == target }) { action in
                    HStack(alignment: .top) {
                        HotKeyListEditor(label: action.rowLabel, combos: cap.shortcut(for: action)) { new in
                            cap.setShortcut(new, for: action); cap.reloadHotKeys(); refresh.toggle()
                        }
                        Spacer()
                        Toggle("In menu", isOn: Binding(
                            get: { cap.showInMenu(action) },
                            set: { cap.setShowInMenu($0, for: action); refresh.toggle() }))
                            .toggleStyle(.checkbox)
                    }
                    Divider()
                }
            }
        }
        .id(refresh)
    }

    private func chooseFolder(_ cap: CaptureFeature) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { cap.setSaveLocation(url); refresh.toggle() }
    }
}

private struct ClipboardPane: View {
    @ObservedObject var features: FeatureManager
    @ObservedObject var clip: ClipboardFeature
    @State private var refresh = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader("Clipboard", "History of what you copy, with a popup to search and paste it back.")
            Toggle("Enable clipboard history", isOn: $features.clipboardEnabled)

            HStack {
                Text("Open history")
                Spacer()
                HotKeyButton(combo: clip.hotKey) { clip.hotKey = $0; refresh.toggle() }
            }
            Text("Default is ⌃V. With the Windows-style modifier swap on an external keyboard, that is the physical Win+V, same as Windows. In the popup: type to search, ↑↓ to move, ↩ to paste into the app you were in, ⌘⌫ to delete an entry, esc to close.")
                .font(.callout).foregroundStyle(.secondary)

            Stepper("Keep the last \(clip.maxItems) items", value: Binding(
                get: { clip.maxItems }, set: { clip.maxItems = $0; refresh.toggle() }), in: 20...2000, step: 20)
                .frame(width: 260)

            HStack(spacing: 24) {
                Stepper("nanoid length: \(clip.nanoidLength)", value: Binding(
                    get: { clip.nanoidLength }, set: { clip.nanoidLength = $0; refresh.toggle() }), in: 8...64)
                    .frame(width: 200)
                Toggle("Uppercase UUIDs", isOn: Binding(
                    get: { clip.uuidUppercase }, set: { clip.uuidUppercase = $0; refresh.toggle() }))
            }
            Text("The popup has UUID (⌘U) and nanoid (⌘N) buttons: generate, copy, and paste in one go. The value lands in the history too.")
                .font(.callout).foregroundStyle(.secondary)

            Toggle("Pause while a password manager is frontmost", isOn: Binding(
                get: { clip.pauseForPasswordManagers }, set: { clip.pauseForPasswordManagers = $0; refresh.toggle() }))
            Text("Content that apps mark as concealed or transient (password fields, autofill) is never recorded regardless. Text, images and copied files are kept in ~/Library/Application Support/Filip's Mac Fixes, on this Mac only.")
                .font(.callout).foregroundStyle(.secondary)

            HStack {
                Button("Open history now") { clip.showPanel() }
                Button("Clear history (\(clip.items.count) items)", role: .destructive) { clip.clear() }
                    .disabled(clip.items.isEmpty)
            }
        }
        .id(refresh)
    }
}

private struct KeyboardPane: View {
    @ObservedObject var features: FeatureManager
    @ObservedObject var swap: ModifierSwap
    @ObservedObject var browsers: BrowserShortcuts
    @State private var refresh = false

    var body: some View {
        let kb = features.keyboard
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader("Keyboard", "Windows muscle memory across the built-in and external keyboards.")

            Toggle("Windows-style modifier keys (persistent)", isOn: Binding(
                get: { kb.swapModifiers }, set: { kb.swapModifiers = $0; refresh.toggle() }))
            Text("Makes the corner key act as Command so Ctrl+C/V/Z/S work the Windows way. External keyboards swap Ctrl↔Command; the built-in maps Fn→Command but leaves Control alone. Reapplied on login and hot-plug.")
                .font(.callout).foregroundStyle(.secondary)

            ForEach(swap.conflicts) { conflict in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 6) {
                        if conflict.awaitingReattach {
                            Text("\(conflict.name): unplug it and plug it back in (or restart) to finish handing the remap to Mac Fixes.")
                        } else {
                            Text("\(conflict.name) has its own map in System Settings › Keyboard › Modifier Keys, so Mac Fixes is not remapping it. macOS stacks the two and they cancel out.")
                            Button("Reset it to default and let Mac Fixes remap it") { swap.resetSystemSettingsMap(conflict) }
                        }
                    }
                    .font(.callout)
                }
            }

            Divider()

            Toggle("Enable text-navigation, task manager and tap-to-launch", isOn: $features.keyboardEnabled)
            Text("The rules below need this on. They assume the swap above is enabled.")
                .font(.callout).foregroundStyle(.secondary)

            Group {
                ruleToggle("Home / End jump to line start / end",
                           get: { kb.homeEndEnabled }, set: { kb.homeEndEnabled = $0 })
                ruleToggle("Ctrl + ← / → jump by word",
                           get: { kb.wordJumpEnabled }, set: { kb.wordJumpEnabled = $0 })
                ruleToggle("Ctrl + Home / End jump to document top / bottom",
                           get: { kb.docNavEnabled }, set: { kb.docNavEnabled = $0 })
                ruleToggle("Ctrl + Backspace deletes the previous word",
                           get: { kb.wordDeleteEnabled }, set: { kb.wordDeleteEnabled = $0 })
                ruleToggle("Ctrl + Shift + Esc opens Activity Monitor",
                           get: { kb.taskManagerEnabled }, set: { kb.taskManagerEnabled = $0 })
                ruleToggle("Tap a modifier key alone to open a launcher",
                           get: { kb.tapToLaunchEnabled }, set: { kb.tapToLaunchEnabled = $0 })
            }
            .disabled(!features.keyboardEnabled)

            HStack {
                Text("Tap-to-launch key")
                Spacer()
                Picker("", selection: Binding(
                    get: { kb.launchTrigger }, set: { kb.launchTrigger = $0; refresh.toggle() })) {
                    ForEach(KeyboardFeature.LaunchTrigger.allCases) {
                        Text($0.label(windowsStyle: kb.swapModifiers)).tag($0)
                    }
                }
                .labelsHidden().frame(width: 200)
            }
            .disabled(!features.keyboardEnabled || !kb.tapToLaunchEnabled)

            HStack {
                Text("Launcher shortcut")
                Spacer()
                HotKeyButton(combo: kb.launcherCombo) { kb.launcherCombo = $0; refresh.toggle() }
            }
            .disabled(!features.keyboardEnabled || !kb.tapToLaunchEnabled)
            Text("Tap the chosen key alone to fire the shortcut. Default is ⌘Space (Spotlight). If you pick Globe, set System Settings → Keyboard → ‘Press 🌐 key to’ to ‘Do Nothing’.")
                .font(.callout).foregroundStyle(.secondary)

            Divider()

            Toggle("Windows browser shortcuts (F5 refresh)", isOn: Binding(
                get: { browsers.applied }, set: { $0 ? browsers.apply() : browsers.remove() }))
            Text("Sets F5 to refresh in each installed browser (Safari also gets Ctrl+F5 for a hard refresh). Restart the browser to pick it up.")
                .font(.callout).foregroundStyle(.secondary)
            if browsers.needsFullDiskAccess {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Safari needs Full Disk Access before Mac Fixes can set its shortcuts.")
                        Button("Open Full Disk Access settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    .font(.callout)
                }
            }
        }
        .id(refresh)
    }

    private func ruleToggle(_ label: String, get: @escaping @Sendable () -> Bool,
                            set: @escaping @Sendable (Bool) -> Void) -> some View {
        Toggle(label, isOn: Binding(get: get, set: { set($0); refresh.toggle() }))
    }
}

private struct WindowsPane: View {
    @ObservedObject var features: FeatureManager
    @State private var refresh = false

    var body: some View {
        let win = features.windows
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader("Windows", "Snapping, maximize, and Windows-like window controls.")
            Toggle("Enable window management", isOn: $features.windowsEnabled)

            Group {
                toggle("Snap & maximize keyboard shortcuts",
                       get: { win.snappingEnabled }, set: { win.snappingEnabled = $0 })
                toggle("Drag a window to a screen edge to snap it (adaptive)",
                       get: { win.dragSnapEnabled }, set: { win.dragSnapEnabled = $0 })
                toggle("Drag the divider between two snapped windows to resize both",
                       get: { win.dividerResizeEnabled }, set: { win.dividerResizeEnabled = $0 })
                toggle("Focus the window under the cursor (hover to focus)",
                       get: { win.focusFollowsEnabled }, set: { win.focusFollowsEnabled = $0 })
                toggle("…and bring it to the front",
                       get: { win.focusRaises }, set: { win.focusRaises = $0 })
                    .padding(.leading, 20)
                toggle("Closing the last window quits the app",
                       get: { win.closeQuitsEnabled }, set: { win.closeQuitsEnabled = $0 })
            }
            .disabled(!features.windowsEnabled)

            Text("Turning drag-snap on disables macOS's built-in edge-tiling so they don't fight, and our snap fills the space left by other windows (drag to a corner to take that gap, half-height). Turning it off restores macOS tiling.")
                .font(.callout).foregroundStyle(.secondary)

            Divider()
            Text("Keyboard shortcuts (Control + Option):").fontWeight(.medium)
            Text("Maximize ⌃⌥↩  ·  Halves ⌃⌥ ← → ↑ ↓  ·  Quarters ⌃⌥ U I J K  ·  Centre ⌃⌥ C")
                .font(.callout).foregroundStyle(.secondary)
        }
        .id(refresh)
    }

    private func toggle(_ label: String, get: @escaping @Sendable () -> Bool,
                        set: @escaping @Sendable (Bool) -> Void) -> some View {
        Toggle(label, isOn: Binding(get: get, set: { set($0); refresh.toggle() }))
    }
}

private struct TweaksPane: View {
    @ObservedObject var tweaks: SystemTweaks
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader("System Tweaks", "One button each. Reset restores the macOS default.")
            ForEach(SystemTweaks.all) { tweak in
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: Binding(
                        get: { tweaks.isApplied(tweak) },
                        set: { _ in tweaks.toggle(tweak) })) {
                        Text(tweak.title).fontWeight(.medium)
                    }
                    Text(tweak.detail + (tweak.needsRelogin ? " (needs logout/app relaunch)" : ""))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Divider()
            }
        }
    }
}

private struct PermissionsPane: View {
    @State private var tick = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader("Permissions", "Grant these so the fixes can work.")
            PermRow(name: "Accessibility",
                    granted: Permissions.hasAccessibility,
                    detail: "Scroll fix, window management, keyboard remaps.") {
                Permissions.promptAccessibility()
                Permissions.openSettings(.accessibility)
            }
            PermRow(name: "Input Monitoring",
                    granted: Permissions.hasInputMonitoring,
                    detail: "Keyboard remapping and tap-to-launch.") {
                Permissions.requestInputMonitoring()
                Permissions.openSettings(.inputMonitoring)
            }
            PermRow(name: "Screen Recording",
                    granted: Permissions.hasScreenRecording,
                    detail: "Screenshots and screen recording.") {
                Permissions.requestScreenRecording()
                Permissions.openSettings(.screenRecording)
            }
            Button("Refresh status") { tick.toggle() }
        }
        .id(tick)
    }
}

private struct AboutPane: View {
    @ObservedObject var features: FeatureManager
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PaneHeader("Filip's Mac Fixes", "Small fixes for the things macOS gets wrong.")
            Toggle("Launch at login", isOn: $features.launchAtLogin)
            Text("Needed for the external-keyboard modifier swap to be in place after a restart.")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            Text("Free and open source. MIT licensed.").foregroundStyle(.secondary)
            Text("Each fix is an independent toggle. Nothing runs unless you turn it on.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Small building blocks

private struct PaneHeader: View {
    let title: String; let subtitle: String
    init(_ t: String, _ s: String) { title = t; subtitle = s }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2).fontWeight(.semibold)
            Text(subtitle).foregroundStyle(.secondary)
        }
    }
}

private struct PermRow: View {
    let name: String; let granted: Bool; let detail: String; let action: () -> Void
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Grant", action: action) }
        }
        Divider()
    }
}
