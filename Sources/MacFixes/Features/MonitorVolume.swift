import AppKit
import IOKit
import CoreGraphics

// Private IOAVService symbols (Apple Silicon DDC), the same ones MonitorControl
// uses. They live in the IOKit framework but aren't in the public headers.
@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ offset: UInt32,
                                 _ inputBuffer: UnsafeMutableRawPointer, _ inputBufferSize: UInt32) -> IOReturn

/// Sends DDC/CI commands to an external monitor to change its built-in speaker
/// volume (VCP 0x62) and mute (VCP 0x8D). Apple Silicon only; works only if the
/// monitor accepts DDC audio commands.
final class MonitorDDC: @unchecked Sendable {
    private var service: CFTypeRef?
    private(set) var level = 50      // our tracked 0-100 value
    private var muted = false

    @discardableResult
    func connect() -> Bool {
        service = Self.firstExternalAVService()
        return service != nil
    }

    func setVolume(_ v: Int) {
        level = min(100, max(0, v))
        muted = false
        write(vcp: 0x62, value: UInt16(level))
    }

    func step(_ delta: Int) { setVolume(level + delta) }

    func toggleMute() {
        muted.toggle()
        write(vcp: 0x8D, value: muted ? 1 : 2)   // 1 = mute, 2 = unmute
    }

    private func write(vcp: UInt8, value: UInt16) {
        guard let service else { return }
        // DDC/CI "Set VCP Feature": [length, 0x03, vcp, hi, lo, checksum].
        var packet: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF)]
        var chk: UInt8 = 0x6E ^ 0x51                 // dest addr ^ source addr
        for b in packet { chk ^= b }
        packet.append(chk)
        _ = packet.withUnsafeMutableBytes {
            IOAVServiceWriteI2C(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count))
        }
    }

    private static func firstExternalAVService() -> CFTypeRef? {
        var iter = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("DCPAVServiceProxy"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var result: CFTypeRef?
        var svc = IOIteratorNext(iter)
        while svc != 0 {
            if let locRef = IORegistryEntryCreateCFProperty(svc, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
               let loc = locRef as? String, loc == "External" {
                result = IOAVServiceCreateWithService(kCFAllocatorDefault, svc)?.takeRetainedValue()
            }
            IOObjectRelease(svc)
            if result != nil { break }
            svc = IOIteratorNext(iter)
        }
        return result
    }
}

/// Intercepts the volume media keys and drives the external monitor's volume
/// over DDC (for monitors macOS treats as fixed-volume, e.g. HDMI displays).
final class MonitorVolumeFeature: Feature, @unchecked Sendable {
    private var tap: CFMachPort?
    private let ddc = MonitorDDC()
    private let step = 6

    // NX system-defined media-key codes.
    private let soundUp = 0, soundDown = 1, mute = 7

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard ddc.connect() else {
            trace("MonitorVolume", "no external DDC display found")
            return false
        }
        let mask = CGEventMask(1 << 14)   // NX_SYSDEFINED
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: mediaKeyCallback, userInfo: refcon) else {
            Permissions.promptAccessibility()
            return false
        }
        tap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    func stop() {
        // Restore the monitor to full volume so switching it to another input
        // (e.g. a Windows laptop, which does its own software volume) is correct.
        ddc.setVolume(100)
        guard let t = tap else { return }
        CGEvent.tapEnable(tap: t, enable: false)
        if let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0) {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
        }
        CFMachPortInvalidate(t)
        tap = nil
    }

    fileprivate func reenable() { if let t = tap { CGEvent.tapEnable(tap: t, enable: true) } }

    /// Returns true to swallow the media-key event.
    fileprivate func handle(_ event: CGEvent) -> Bool {
        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }
        let keyCode = Int((ns.data1 & 0xFFFF0000) >> 16)
        guard keyCode == soundUp || keyCode == soundDown || keyCode == mute else { return false }
        let keyDown = ((ns.data1 & 0xFF00) >> 8) == 0x0A
        if keyDown {
            switch keyCode {
            case soundUp:   ddc.step(step)
            case soundDown: ddc.step(-step)
            case mute:      ddc.toggleMute()
            default:        break
            }
        }
        return true   // swallow both down and up so macOS's own handling is skipped
    }
}

private func mediaKeyCallback(proxy: CGEventTapProxy, type: CGEventType,
                              event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let me = Unmanaged<MonitorVolumeFeature>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        me.reenable()
        return Unmanaged.passUnretained(event)
    }
    if me.handle(event) { return nil }
    return Unmanaged.passUnretained(event)
}
