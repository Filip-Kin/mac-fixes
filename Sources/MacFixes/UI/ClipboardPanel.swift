import AppKit
import SwiftUI
import Carbon.HIToolbox

/// The clipboard-history popup: a floating, non-activating panel (so the app
/// you are typing in stays frontmost and receives the paste), with a search
/// field, arrow-key navigation, Return to paste, ⌘⌫ to delete, Esc to close.
@MainActor
final class ClipboardPanel {
    private unowned let feature: ClipboardFeature
    private let model = ClipboardPanelModel()
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private let size = NSSize(width: 460, height: 500)

    init(feature: ClipboardFeature) { self.feature = feature }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        let p = panel ?? makePanel()
        model.query = ""
        model.selection = 0

        // Centre on the screen that has the mouse, a little above the middle.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2 + vf.height * 0.08)
        p.setFrame(NSRect(origin: origin, size: size), display: false)
        p.makeKeyAndOrderFront(nil)
        model.focusSearch += 1

        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let consumed: Bool = MainActor.assumeIsolated { self.handle(event) }
                return consumed ? nil : event
            }
        }
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }
    }

    func close() {
        panel?.orderOut(nil)
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let o = resignObserver { NotificationCenter.default.removeObserver(o); resignObserver = nil }
    }

    private var filtered: [ClipItem] { ClipboardPanelModel.filter(feature.items, model.query) }

    /// Returns true if the key was handled (and should not reach the search field).
    private func handle(_ event: NSEvent) -> Bool {
        let list = filtered
        switch Int(event.keyCode) {
        case kVK_Escape:
            close(); return true
        case kVK_DownArrow:
            if !list.isEmpty { model.selection = min(model.selection + 1, list.count - 1) }
            return true
        case kVK_UpArrow:
            model.selection = max(model.selection - 1, 0); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if list.indices.contains(model.selection) { feature.paste(list[model.selection]) }
            return true
        case kVK_ANSI_U where event.modifierFlags.contains(.command):
            feature.generateAndPaste(feature.newUUID()); return true
        case kVK_ANSI_N where event.modifierFlags.contains(.command):
            feature.generateAndPaste(feature.newNanoid()); return true
        case kVK_Delete where event.modifierFlags.contains(.command):
            if list.indices.contains(model.selection) {
                feature.delete(list[model.selection])
                model.selection = min(model.selection, max(filtered.count - 1, 0))
            }
            return true
        default:
            return false
        }
    }

    private func makePanel() -> NSPanel {
        let p = KeyablePanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                             backing: .buffered, defer: false)
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: ClipboardListView(feature: feature, model: model,
                                                              onPaste: { [weak self] in self?.feature.paste($0) },
                                                              onDelete: { [weak self] in self?.feature.delete($0) },
                                                              onGenerate: { [weak self] in self?.feature.generateAndPaste($0) }))
        host.frame = NSRect(origin: .zero, size: size)
        p.contentView = host
        panel = p
        return p
    }
}

/// A borderless panel that can take keyboard focus without activating the app.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ClipboardPanelModel: ObservableObject {
    @Published var query = ""
    @Published var selection = 0
    @Published var focusSearch = 0

    static func filter(_ items: [ClipItem], _ query: String) -> [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { $0.preview.localizedCaseInsensitiveContains(q) }
    }
}

struct ClipboardListView: View {
    @ObservedObject var feature: ClipboardFeature
    @ObservedObject var model: ClipboardPanelModel
    let onPaste: (ClipItem) -> Void
    let onDelete: (ClipItem) -> Void
    let onGenerate: (String) -> Void
    @FocusState private var searchFocused: Bool

    private var filtered: [ClipItem] { ClipboardPanelModel.filter(feature.items, model.query) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search clipboard history", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($searchFocused)
                Text("\(filtered.count)").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            Divider()

            if filtered.isEmpty {
                Spacer()
                Text(feature.items.isEmpty ? "Nothing copied yet" : "No matches")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, item in
                                ClipRow(item: item, selected: idx == model.selection)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { onPaste(item) }
                                    .contextMenu {
                                        Button("Paste") { onPaste(item) }
                                        Button("Delete", role: .destructive) { onDelete(item) }
                                    }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: model.selection) { _, sel in
                        let list = filtered
                        if list.indices.contains(sel) { proxy.scrollTo(list[sel].id, anchor: .center) }
                    }
                }
            }

            Divider()
            HStack(spacing: 8) {
                Button { onGenerate(feature.newUUID()) } label: { Label("UUID", systemImage: "number") }
                    .help("Generate a UUID and paste it (⌘U)")
                Button { onGenerate(feature.newNanoid()) } label: { Label("nanoid", systemImage: "textformat.abc") }
                    .help("Generate a nanoid and paste it (⌘N)")
                Spacer()
                HStack(spacing: 12) {
                    hint("↩", "paste"); hint("⌘⌫", "delete"); hint("esc", "close")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .controlSize(.small)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 460, height: 500)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary))
        .onAppear { searchFocused = true }
        .onChange(of: model.focusSearch) { _, _ in searchFocused = true }
        .onChange(of: model.query) { _, _ in model.selection = 0 }
    }

    private func hint(_ key: String, _ what: String) -> some View {
        HStack(spacing: 4) {
            Text(key).padding(.horizontal, 5).padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(what)
        }
    }
}

private struct ClipRow: View {
    let item: ClipItem
    let selected: Bool
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short; return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.preview.isEmpty ? " " : item.preview)
                    .lineLimit(2)
                    .font(.system(size: 13, design: item.kind == .text ? .default : .default))
                Text(Self.relative.localizedString(for: item.date, relativeTo: Date()))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(selected ? Color.accentColor.opacity(0.22) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder private var icon: some View {
        switch item.kind {
        case .image:
            if let name = item.imageFile,
               let img = NSImage(contentsOf: ClipboardFeature.imagesDir.appendingPathComponent(name)) {
                Image(nsImage: img).resizable().scaledToFill()
                    .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        case .files:
            Image(systemName: "doc.on.doc").font(.title3).foregroundStyle(.secondary)
        case .text:
            Image(systemName: "text.alignleft").font(.title3).foregroundStyle(.secondary)
        }
    }
}
