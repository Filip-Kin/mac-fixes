import SwiftUI
import AppKit

/// A blur background that stays the same whether or not its window is focused
/// (`state = .active`), so the always-visible taskbar doesn't switch between
/// frosted and clear as you focus other apps.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = cornerRadius
        v.layer?.masksToBounds = true
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.state = .active
        v.layer?.cornerRadius = cornerRadius
    }
}

extension View {
    /// macOS 26 Liquid Glass background in a rounded rectangle, falling back to a
    /// material on older systems. Used for the taskbar, Start menu and switcher.
    @ViewBuilder
    func liquidGlass(_ cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    /// A rounded, focus-independent frosted panel with cleanly transparent
    /// corners (no black edge), for the pop-ups. Uses the light, adaptive
    /// popover material rather than the dark HUD one.
    func glassPanel(_ cornerRadius: CGFloat) -> some View {
        // The effect view rounds its own layer, so there is no square backing
        // behind the corners to show as a dark border.
        self.background(VisualEffectBackground(material: .popover, cornerRadius: cornerRadius))
    }
}
