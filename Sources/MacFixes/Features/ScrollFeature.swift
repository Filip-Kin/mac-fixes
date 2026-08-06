import AppKit
import CoreGraphics

/// Per-device scroll direction.
///
/// macOS "natural scrolling" is a single system-wide switch. This leaves it ON
/// (so the trackpad scrolls naturally) and inverts ONLY physical mouse-wheel
/// scrolls, so a mouse behaves traditionally.
///
/// Detection: trackpad / Magic Mouse scrolls are "continuous" (pixel/momentum);
/// a physical scroll wheel is not. We invert the non-continuous ones.
final class ScrollFeature: Feature {
    private var tap: CFMachPort?

    /// Toggled by the settings UI; read on the tap thread.
    var invertMouse = true

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: scrollCallback,
                                          userInfo: refcon) else {
            Permissions.promptAccessibility()
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
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
}

private func scrollCallback(proxy: CGEventTapProxy,
                            type: CGEventType,
                            event: CGEvent,
                            refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let feature = Unmanaged<ScrollFeature>.fromOpaque(refcon).takeUnretainedValue()

    // The system disables the tap on timeout / heavy input. Re-enable it.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        feature.reenable()
        return Unmanaged.passUnretained(event)
    }

    guard type == .scrollWheel, feature.invertMouse else {
        return Unmanaged.passUnretained(event)
    }

    // Non-continuous == physical mouse wheel. Invert its vertical axis.
    if event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 {
        let line = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -line)

        let point = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -point)

        let fixed = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixed)
    }

    return Unmanaged.passUnretained(event)
}
