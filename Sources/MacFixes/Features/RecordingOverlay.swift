import AppKit
import SwiftUI

/// While recording, shows a red border around the captured area and a Stop /
/// Cancel bar just below it. Both sit OUTSIDE the captured rectangle (the border
/// is a ring just beyond the area, the bar is below it), so neither is recorded.
final class RecordingOverlay: @unchecked Sendable {
    private var border: NSWindow?
    private var controls: NSWindow?

    func show(areaAX: CGRect, onStop: @escaping @Sendable () -> Void, onCancel: @escaping @Sendable () -> Void) {
        MainActor.assumeIsolated {
            let area = AXWindow.toBottomLeft(areaAX)   // bottom-left screen coords
            let bw: CGFloat = 3

            // Border ring: window is the area grown by `bw`; the inner border of
            // that width lands in the outer ring, just outside the captured area.
            let borderFrame = area.insetBy(dx: -bw, dy: -bw)
            let b = NSWindow(contentRect: borderFrame, styleMask: .borderless, backing: .buffered, defer: false)
            b.level = .statusBar
            b.backgroundColor = .clear
            b.isOpaque = false
            b.ignoresMouseEvents = true
            b.hasShadow = false
            let bview = NSView(frame: CGRect(origin: .zero, size: borderFrame.size))
            bview.wantsLayer = true
            bview.layer?.borderColor = NSColor.systemRed.cgColor
            bview.layer?.borderWidth = bw
            b.contentView = bview
            b.orderFront(nil)
            border = b

            // Control bar centred below the area — or above it if the area is
            // near the bottom of the screen (so the buttons stay reachable).
            let size = CGSize(width: 200, height: 44)
            let host = NSHostingView(rootView: RecordingControls(onStop: onStop, onCancel: onCancel))
            host.frame = CGRect(origin: .zero, size: size)
            let screenBottom = (NSScreen.screens.first { $0.frame.intersects(area) } ?? NSScreen.main)?
                .visibleFrame.minY ?? 0
            let below = area.minY - size.height - 8
            let cy = below < screenBottom ? area.maxY + 8 : below
            let cFrame = CGRect(x: area.midX - size.width / 2, y: cy,
                                width: size.width, height: size.height)
            let c = NSWindow(contentRect: cFrame, styleMask: .borderless, backing: .buffered, defer: false)
            c.level = .statusBar
            c.backgroundColor = .clear
            c.isOpaque = false
            c.hasShadow = false
            c.contentView = host
            c.orderFront(nil)
            controls = c
        }
    }

    func hide() {
        MainActor.assumeIsolated {
            border?.orderOut(nil); border = nil
            controls?.orderOut(nil); controls = nil
        }
    }
}

private struct RecordingControls: View {
    let onStop: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onStop) {
                Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .tint(.red)
            Button(action: onCancel) {
                Label("Cancel", systemImage: "xmark")
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
