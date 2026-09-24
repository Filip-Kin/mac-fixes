import AppKit
import SwiftUI

/// In-app banners (top-right, stacked, AirDrop style) instead of system
/// notifications: macOS refuses notifications for this self-signed app without
/// ever showing the permission prompt ("Notifications are not allowed for this
/// application"), so the app never appears in System Settings › Notifications.
enum Notifier {
    struct Action: @unchecked Sendable {
        let title: String
        let run: @MainActor () -> Void
    }

    /// A text field under the banner; `send` gets what was typed.
    struct Reply: @unchecked Sendable {
        let placeholder: String
        let send: @MainActor (String) -> Void
    }

    struct Banner: @unchecked Sendable {
        /// Posting again with the same id updates that banner in place.
        var id = UUID().uuidString
        var title: String
        var body: String
        var image: NSImage?
        /// Small line above the title (e.g. "WhatsApp · Pixel 9 Pro").
        var caption: String? = nil
        /// Files get Open / Show in Finder buttons (one file) or Show in Finder (several).
        var files: [URL] = []
        /// 0...1 shows a progress bar; the banner stays until updated or closed.
        var progress: Double?
        var actions: [Action] = []
        var reply: Reply?
        /// Called when the user closes it with the × (not on timeout).
        var onDismiss: (@MainActor () -> Void)?
        /// Seconds before it hides itself; nil keeps it until closed.
        var timeout: TimeInterval? = 6
    }

    /// Simple banner. `reveal`: a file, shown with Open / Show in Finder.
    static func post(title: String, body: String, reveal: URL? = nil, action: Action? = nil) {
        var b = Banner(title: title, body: body)
        if let reveal { b.files = [reveal] }
        if let action { b.actions = [action] }
        if reveal != nil || action != nil { b.timeout = 15 }
        show(b)
    }

    static func show(_ banner: Banner) {
        DispatchQueue.main.async { MainActor.assumeIsolated { BannerCenter.shared.show(banner) } }
    }

    static func close(_ id: String) {
        DispatchQueue.main.async { MainActor.assumeIsolated { BannerCenter.shared.close(id) } }
    }
}

// MARK: - Banner stack

@MainActor
private final class BannerCenter {
    static let shared = BannerCenter()

    private final class Entry {
        let panel: BannerPanel
        let model: BannerModel
        var timer: DispatchWorkItem?
        init(panel: BannerPanel, model: BannerModel) { self.panel = panel; self.model = model }
    }
    private var entries: [(id: String, entry: Entry)] = []
    private let maxVisible = 4
    private let width: CGFloat = 360

    func show(_ b: Notifier.Banner) {
        if let e = entries.first(where: { $0.id == b.id })?.entry {
            e.model.banner = b
            schedule(b.id, e, b.timeout)
            layout()
            // SwiftUI resizes on the next pass (e.g. buttons appearing).
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.layout() } }
            return
        }
        let model = BannerModel(b)
        let panel = BannerPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 80),
                                styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let id = b.id
        let view = BannerView(model: model,
                              close: { [weak self] in self?.close(id) },
                              dismiss: { [weak self] in
                                  let handler = model.banner.onDismiss
                                  self?.close(id)
                                  handler?()
                              },
                              hover: { [weak self] inside in self?.hover(id, inside) },
                              resized: { [weak self] in self?.layout() })
        panel.contentView = NSHostingView(rootView: view)
        let entry = Entry(panel: panel, model: model)
        entries.insert((id, entry), at: 0)
        while entries.count > maxVisible { remove(entries[entries.count - 1].id) }
        layout()
        panel.orderFrontRegardless()
        schedule(id, entry, b.timeout)
    }

    func close(_ id: String) {
        remove(id)
        layout()
    }

    private func remove(_ id: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].entry.timer?.cancel()
        entries[i].entry.panel.orderOut(nil)
        entries.remove(at: i)
    }

    private func schedule(_ id: String, _ e: Entry, _ timeout: TimeInterval?) {
        e.timer?.cancel()
        e.timer = nil
        guard let timeout, e.model.banner.progress == nil else { return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.close(id) } }
        e.timer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    /// Hovering holds the banner (e.g. while typing a reply).
    private func hover(_ id: String, _ inside: Bool) {
        guard let e = entries.first(where: { $0.id == id })?.entry else { return }
        if inside { e.timer?.cancel(); e.timer = nil }
        else if e.model.banner.timeout != nil { schedule(id, e, 4) }
    }

    /// Newest on top, stacked downward from the top-right corner.
    private func layout() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        var top = screen.maxY - 12
        for (_, e) in entries {
            let size = e.panel.contentView?.fittingSize ?? NSSize(width: width, height: 80)
            e.panel.setFrame(NSRect(x: screen.maxX - size.width - 12, y: top - size.height,
                                    width: size.width, height: size.height), display: true)
            top -= size.height + 8
        }
    }
}

/// Can take keyboard focus (for the reply field) without activating the app.
private final class BannerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class BannerModel: ObservableObject {
    @Published var banner: Notifier.Banner
    init(_ b: Notifier.Banner) { banner = b }
}

private struct BannerView: View {
    @ObservedObject var model: BannerModel
    let close: () -> Void
    let dismiss: () -> Void
    let hover: (Bool) -> Void
    let resized: () -> Void
    @State private var reply = ""

    var body: some View {
        let b = model.banner
        HStack(alignment: .top, spacing: 12) {
            icon(b)
            VStack(alignment: .leading, spacing: 4) {
                if let caption = b.caption {
                    Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(b.title).fontWeight(.semibold).lineLimit(2)
                if !b.body.isEmpty {
                    Text(b.body).font(.callout).foregroundStyle(.secondary).lineLimit(4)
                }
                if let p = b.progress {
                    ProgressView(value: p).progressViewStyle(.linear).padding(.top, 2)
                }
                if !b.files.isEmpty || !b.actions.isEmpty {
                    HStack {
                        if b.files.count == 1, let f = b.files.first {
                            Button("Open") { NSWorkspace.shared.open(f); close() }
                                .keyboardShortcut(.defaultAction)
                        }
                        if !b.files.isEmpty {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(b.files); close() }
                        }
                        ForEach(Array(b.actions.enumerated()), id: \.offset) { _, a in
                            Button(a.title) { a.run(); close() }
                        }
                    }
                    .padding(.top, 4)
                }
                if let r = b.reply {
                    HStack {
                        TextField(r.placeholder, text: $reply)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { submit(r) }
                        Button("Send") { submit(r) }.disabled(reply.isEmpty)
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
            Button { dismiss() } label: { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        .onHover { hover($0) }
        .onChange(of: model.banner.body) { _, _ in resized() }
        .onChange(of: model.banner.title) { _, _ in resized() }
    }

    @ViewBuilder private func icon(_ b: Notifier.Banner) -> some View {
        if let img = b.image {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if let f = b.files.first {
            Image(nsImage: NSWorkspace.shared.icon(forFile: f.path)).resizable().frame(width: 40, height: 40)
        } else {
            Image(systemName: "iphone").font(.system(size: 26)).frame(width: 40, height: 40)
        }
    }

    private func submit(_ r: Notifier.Reply) {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        r.send(text)
        reply = ""
        close()
    }
}
