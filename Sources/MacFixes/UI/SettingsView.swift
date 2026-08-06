import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case scroll = "Scroll"
    case capture = "Screen Capture"
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
                    case .keyboard: KeyboardPane(features: features)
                    case .windows: WindowsPane(features: features)
                    case .tweaks: TweaksPane(tweaks: features.tweaks)
                    case .permissions: PermissionsPane()
                    case .about: AboutPane()
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

private struct KeyboardPane: View {
    @ObservedObject var features: FeatureManager
    @State private var refresh = false

    var body: some View {
        let kb = features.keyboard
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader("Keyboard", "Windows muscle memory across the built-in and external keyboards.")

            Toggle("Windows-style modifier keys (persistent)", isOn: Binding(
                get: { kb.swapModifiers }, set: { kb.swapModifiers = $0; refresh.toggle() }))
            Text("Makes the corner key act as Command so Ctrl+C/V/Z/S work the Windows way. External keyboards: Ctrl↔Command (Windows key becomes Control). Built-in: Fn→Command, Option→Globe, Command→Option, and Control stays Control (so Ctrl+C still kills terminal processes). Applied at the hardware level and reapplied on login and keyboard hot-plug.")
                .font(.callout).foregroundStyle(.secondary)

            Divider()

            Toggle("Enable text-navigation and tap-to-launch", isOn: $features.keyboardEnabled)
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
            Text("Tap the chosen key alone to fire the shortcut. Default shortcut is ⌘Space (Spotlight); set it to your launcher’s, e.g. Raycast. If you pick Globe, set System Settings → Keyboard → ‘Press 🌐 key to’ to ‘Do Nothing’ so it doesn’t also open emoji.")
                .font(.callout).foregroundStyle(.secondary)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PaneHeader("Filip's Mac Fixes", "Small fixes for the things macOS gets wrong.")
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
