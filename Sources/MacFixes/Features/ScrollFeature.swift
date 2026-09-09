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
///
/// Mechanism: the tap REPLACES the event with a freshly built one rather than
/// editing the original's fields. Since macOS 26.6.x the window server
/// re-derives the point and fixed-point deltas of a hardware-backed scroll
/// event from its raw HID data after the tap stages run, so negating those
/// fields in place (or on a copy) no longer sticks: only the line delta
/// flipped, and modern apps scroll by the point delta, so the direction did
/// not change. A fresh event has no HID backing, so its fields are delivered
/// to apps exactly as set.
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

/// Points per wheel line the window server assigns to a physical mouse wheel
/// (observed on macOS 26.6.2: point delta = 8 × line, fixed-point delta = line).
/// Applied to the replacement event so scroll speed is unchanged.
private let pointsPerLine: Int64 = 8

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

    // Non-continuous == physical mouse wheel. Anything else passes through.
    guard type == .scrollWheel, feature.invertMouse,
          event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else {
        return Unmanaged.passUnretained(event)
    }

    // Vertical axis inverted; horizontal left as-is.
    let line1 = -event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
    let line2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)

    guard let replacement = CGEvent(scrollWheelEvent2Source: nil,
                                    units: .line,
                                    wheelCount: 2,
                                    wheel1: Int32(clamping: line1),
                                    wheel2: Int32(clamping: line2),
                                    wheel3: 0) else {
        return Unmanaged.passUnretained(event)
    }
    replacement.location = event.location
    replacement.flags = event.flags
    replacement.timestamp = event.timestamp
    replacement.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: line1 * pointsPerLine)
    replacement.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(line1))
    replacement.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: line2 * pointsPerLine)
    replacement.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(line2))

    // The tap machinery releases the returned event; hand over our +1.
    return Unmanaged.passRetained(replacement)
}
