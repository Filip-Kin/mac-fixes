import AppKit
import ApplicationServices
import CoreGraphics

/// Double-click a window's title bar to maximize it with our taskbar-aware fill
/// instead of macOS zoom or fullscreen. Also (Windows-style): double-click the
/// top or bottom resize edge to stretch the window to full screen height,
/// keeping its width and X position.
///
/// An event tap swallows the title-bar double-click before macOS sees it, so the
/// OS never runs its own zoom/fill (which would flash first). We then apply our
/// maximize directly. The tap runs on the main run loop, where it is installed.
final class TitlebarMaximize: @unchecked Sendable {
    private var tap: CFMachPort?
    private let titleBandHeight: CGFloat = 30
    private var swallowNextUp = false
    var titlebarEnabled = false
    var edgeEnabled = false

    // Resize-edge hit zone, matching where macOS shows the ↕ cursor: a few
    // points outside the window edge and a couple inside it. Corners (diagonal
    // cursor) are excluded.
    private let edgeOutside: CGFloat = 6
    private let edgeInside: CGFloat = 3
    private let cornerInset: CGFloat = 12

    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask((1 << CGEventType.leftMouseDown.rawValue) |
                               (1 << CGEventType.leftMouseUp.rawValue))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: titlebarCallback,
                                          userInfo: refcon) else { return }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        CFMachPortInvalidate(tap)
        self.tap = nil
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Returns true to swallow the event (a title-bar double-click). Runs on the
    /// main run loop, so applying the frame here is safe.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .leftMouseDown:
            guard event.getIntegerValueField(.mouseEventClickState) == 2 else { return false }
            let p = event.location
            if edgeEnabled, let (win, frame) = edgeWindow(at: p) {
                let vf = AXWindow.axVisibleFrame(AXWindow.screen(forAX: frame))
                let target = CGRect(x: frame.minX, y: vf.minY, width: frame.width, height: vf.height)
                traceAsync("EdgeMax", "\(frame) -> \(target)")
                AXWindow.setFrame(win, target)
                swallowNextUp = true
                return true
            }
            guard titlebarEnabled,
                  let win = AXWindow.frontmostWindow(),
                  let frame = AXWindow.frame(of: win) else { return false }
            // AX frame and CGEvent.location share a top-left origin.
            let band = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: titleBandHeight)
            guard band.contains(p) else { return false }
            let vf = AXWindow.axVisibleFrame(AXWindow.screen(forAX: frame))
            AXWindow.setFrame(win, WindowPosition.maximize.rect(in: vf))
            swallowNextUp = true          // also drop the paired mouse-up
            return true
        case .leftMouseUp:
            if swallowNextUp { swallowNextUp = false; return true }
            return false
        default:
            return false
        }
    }

    /// The window whose top or bottom resize edge is under `p`, if any. Walks
    /// on-screen windows front-to-back and stops at the first one whose
    /// (slightly enlarged) frame holds the point, so a covered edge never counts.
    private func edgeWindow(at p: CGPoint) -> (AXUIElement, CGRect)? {
        for w in AXWindow.allWindows() {
            let f = w.frame
            guard f.insetBy(dx: -edgeOutside, dy: -edgeOutside).contains(p) else { continue }
            guard p.x > f.minX + cornerInset, p.x < f.maxX - cornerInset else { return nil }
            let onTop = p.y >= f.minY - edgeOutside && p.y <= f.minY + edgeInside
            let onBottom = p.y >= f.maxY - edgeInside && p.y <= f.maxY + edgeOutside
            guard onTop || onBottom,
                  let el = AXWindow.element(pid: w.pid, matchingFrame: f),
                  let axFrame = AXWindow.frame(of: el) else { return nil }
            return (el, axFrame)
        }
        return nil
    }
}

private func titlebarCallback(proxy: CGEventTapProxy,
                              type: CGEventType,
                              event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let me = Unmanaged<TitlebarMaximize>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        me.reenable()
        return Unmanaged.passUnretained(event)
    }
    if me.handle(type: type, event: event) { return nil }   // swallow
    return Unmanaged.passUnretained(event)
}
