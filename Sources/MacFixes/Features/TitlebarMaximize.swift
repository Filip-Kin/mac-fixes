import AppKit
import ApplicationServices
import CoreGraphics

/// Double-click a window's title bar to maximize it with our taskbar-aware fill
/// instead of macOS zoom or fullscreen.
///
/// An event tap swallows the title-bar double-click before macOS sees it, so the
/// OS never runs its own zoom/fill (which would flash first). We then apply our
/// maximize directly. The tap runs on the main run loop, where it is installed.
final class TitlebarMaximize: @unchecked Sendable {
    private var tap: CFMachPort?
    private let titleBandHeight: CGFloat = 30
    private var swallowNextUp = false

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
            guard let win = AXWindow.frontmostWindow(),
                  let frame = AXWindow.frame(of: win) else { return false }
            // AX frame and CGEvent.location share a top-left origin.
            let band = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: titleBandHeight)
            guard band.contains(event.location) else { return false }
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
