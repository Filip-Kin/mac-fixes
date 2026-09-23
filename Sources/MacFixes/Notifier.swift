import AppKit
import SwiftUI

/// In-app banners (top-right, AirDrop style) instead of system notifications:
/// macOS refuses notifications for this self-signed app without ever showing
/// the permission prompt ("Notifications are not allowed for this
/// application"), so the app never appears in System Settings › Notifications.
enum Notifier {
    struct Action: @unchecked Sendable {
        let title: String
        let run: @MainActor () -> Void
    }

    /// `reveal`: a file, shown with Open / Show in Finder buttons.
    /// `action`: one extra button.
    static func post(title: String, body: String, reveal: URL? = nil, action: Action? = nil) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                BannerPanel.shared.show(title: title, body: body, file: reveal, action: action)
            }
        }
    }
}

// MARK: - Banner

@MainActor
private final class BannerPanel {
    static let shared = BannerPanel()
    private var panel: NSPanel?
    private var dismiss: DispatchWorkItem?

    func show(title: String, body: String, file: URL?, action: Notifier.Action?) {
        panel?.orderOut(nil)
        let view = BannerView(title: title, message: body, file: file, action: action) { [weak self] in self?.close() }
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        if let screen = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: screen.maxX - host.fittingSize.width - 12,
                                     y: screen.maxY - host.fittingSize.height - 12))
        }
        p.orderFrontRegardless()
        panel = p

        dismiss?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.close() } }
        dismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (file == nil && action == nil ? 5 : 15), execute: work)
    }

    func close() {
        dismiss?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct BannerView: View {
    let title: String
    let message: String
    let file: URL?
    let action: Notifier.Action?
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let file {
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                    .resizable().frame(width: 40, height: 40)
            } else {
                Image(systemName: "iphone").font(.system(size: 26)).frame(width: 40, height: 40)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.semibold).lineLimit(2)
                Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                if let file {
                    HStack {
                        Button("Open") { NSWorkspace.shared.open(file); close() }
                            .keyboardShortcut(.defaultAction)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]); close() }
                    }
                    .padding(.top, 4)
                }
                if let action {
                    Button(action.title) { action.run(); close() }
                        .keyboardShortcut(.defaultAction)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
            Button { close() } label: { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
    }
}
