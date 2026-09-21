import AppKit
import SwiftUI
import CoreAudio
import AudioToolbox

/// Windows-style software volume: taps all system audio, applies a gain, and
/// replays it to the current output device — so the monitor's own volume is
/// never touched (it stays at max), and the volume keys change loudness by
/// attenuating the signal. Uses the macOS 14.2+ Core Audio process-tap API, so
/// no audio driver is installed.
final class SoftwareVolumeFeature: Feature, @unchecked Sendable {
    private var tapID: AudioObjectID = 0
    private var aggID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var keyTap: CFMachPort?

    // `gain` is the linear multiplier applied on the real-time audio thread;
    // `volume` is the 0…1 slider position it is derived from (perceptual curve).
    fileprivate var gain: Float = 1.0
    private var volume: Float = 1.0
    fileprivate var muted = false
    private let step: Float = 0.0625   // 16 steps across the range
    private var savedDeviceVolume: Float?      // volume to restore on the device we forced to 100%
    private var savedDeviceID: AudioObjectID = 0
    private var currentOutputUID: String?      // device the tap is currently built on
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?

    /// Perceptual taper: slider position -> linear gain over a ~60 dB range, so
    /// each step down is an equal-sounding drop instead of a tiny linear one.
    static func gain(for v: Float) -> Float {
        let c = min(1, max(0, v))
        return c <= 0.0005 ? 0 : Float(pow(10.0, Double(c - 1) * 3.0))
    }

    private let soundUp = 0, soundDown = 1, mute = 7

    @discardableResult
    func start() -> Bool {
        guard keyTap == nil else { return true }
        guard #available(macOS 14.2, *) else {
            trace("SoftwareVolume", "needs macOS 14.2+")
            return false
        }
        guard setupTap() else { return false }
        guard installKeyTap() else { return false }
        // Take the hardware output to 100% so software gain has the full range,
        // and carry the old level over as our starting position (errs quiet,
        // never loud). The device stays at 100% because the volume keys are now
        // swallowed and drive software gain instead.
        forceCurrentDeviceToFull()
        volume = min(1, max(0, savedDeviceVolume ?? 1.0))
        gain = Self.gain(for: volume)
        // Rebuild the tap onto the new device when the default output changes,
        // otherwise audio keeps routing to the old device until toggled.
        installDefaultDeviceListener()
        return true
    }

    func stop() {
        removeDefaultDeviceListener()
        if savedDeviceID != 0, let v = savedDeviceVolume { Self.setDeviceVolume(savedDeviceID, v) }
        savedDeviceVolume = nil; savedDeviceID = 0
        teardownAudio()
        if let t = keyTap {
            CGEvent.tapEnable(tap: t, enable: false)
            if let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0) {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
            }
            CFMachPortInvalidate(t)
            keyTap = nil
        }
    }

    // MARK: Output-device switching

    /// Save the current default output's volume and force it to 100%.
    private func forceCurrentDeviceToFull() {
        savedDeviceID = Self.defaultOutputDeviceID() ?? 0
        savedDeviceVolume = savedDeviceID != 0 ? Self.deviceVolume(savedDeviceID) : nil
        if savedDeviceID != 0 { Self.setDeviceVolume(savedDeviceID, 1.0) }
    }

    /// Tear down and rebuild the tap on the new default output. Without this the
    /// aggregate device keeps replaying to the old device after a device switch.
    private func handleDefaultDeviceChanged() {
        guard #available(macOS 14.2, *) else { return }
        let newUID = Self.defaultOutputUID()
        guard newUID != currentOutputUID else { return }
        trace("SoftwareVolume", "default output changed -> \(newUID ?? "nil"); rebuilding tap")
        // Restore the device we're leaving, then take the new one to 100%.
        if savedDeviceID != 0, let v = savedDeviceVolume { Self.setDeviceVolume(savedDeviceID, v) }
        savedDeviceVolume = nil; savedDeviceID = 0
        teardownAudio()
        if setupTap() {
            forceCurrentDeviceToFull()   // keeps the current software volume/gain as-is
        } else {
            trace("SoftwareVolume", "rebuild on new device failed")
        }
    }

    private func installDefaultDeviceListener() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultDeviceChanged()
        }
        defaultDeviceListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
    }

    private func removeDefaultDeviceListener() {
        guard let block = defaultDeviceListener else { return }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        defaultDeviceListener = nil
    }

    private func teardownAudio() {
        if let p = ioProcID, aggID != 0 {
            AudioDeviceStop(aggID, p)
            AudioDeviceDestroyIOProcID(aggID, p)
            ioProcID = nil
        }
        if aggID != 0 { AudioHardwareDestroyAggregateDevice(aggID); aggID = 0 }
        if #available(macOS 14.2, *), tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID); tapID = 0
        }
        currentOutputUID = nil
    }

    // MARK: Audio tap

    @available(macOS 14.2, *)
    private func setupTap() -> Bool {
        guard let outUID = Self.defaultOutputUID() else {
            trace("SoftwareVolume", "no default output device")
            return false
        }
        // Exclude our own audio so our replayed output isn't re-tapped (which
        // both mutes it at the device and creates a feedback loop).
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.selfProcessObjects())
        desc.name = "Mac Fixes Volume"
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped   // silence the normal render; we replay

        var tap: AudioObjectID = 0
        let ts = AudioHardwareCreateProcessTap(desc, &tap)
        guard ts == noErr, tap != 0 else {
            trace("SoftwareVolume", "create tap failed: \(ts) (needs audio-recording permission?)")
            return false
        }
        tapID = tap

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mac Fixes Volume",
            kAudioAggregateDeviceUIDKey: "com.filipkin.macfixes.volume",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        var agg: AudioObjectID = 0
        let as_ = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
        guard as_ == noErr, agg != 0 else {
            trace("SoftwareVolume", "create aggregate failed: \(as_)")
            return false
        }
        aggID = agg

        var proc: AudioDeviceIOProcID?
        let ps = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) { [weak self] _, inInput, _, outOutput, _ in
            guard let self else { return }
            let g = self.muted ? 0 : self.gain
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
            let outs = UnsafeMutableAudioBufferListPointer(outOutput)
            for i in 0..<min(ins.count, outs.count) {
                let ib = ins[i], ob = outs[i]
                guard let ip = ib.mData?.assumingMemoryBound(to: Float.self),
                      let op = ob.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let n = Int(min(ib.mDataByteSize, ob.mDataByteSize)) / MemoryLayout<Float>.size
                for s in 0..<n { op[s] = ip[s] * g }
            }
        }
        guard ps == noErr, let proc else {
            trace("SoftwareVolume", "create IOProc failed: \(ps)")
            return false
        }
        ioProcID = proc
        let ss = AudioDeviceStart(agg, proc)
        guard ss == noErr else {
            trace("SoftwareVolume", "device start failed: \(ss)")
            return false
        }
        currentOutputUID = outUID
        trace("SoftwareVolume", "tap running on \(outUID)")
        return true
    }

    /// Our own process's audio object(s), to exclude from the tap.
    @available(macOS 14.2, *)
    private static func selfProcessObjects() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var obj = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return (st == noErr && obj != 0) ? [obj] : []
    }

    private static func defaultOutputDeviceID() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
              dev != 0 else { return nil }
        return dev
    }

    private static func defaultOutputUID() -> String? {
        guard let dev = defaultOutputDeviceID() else { return nil }
        var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uid: CFString?
        var usize = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(dev, &uidAddr, 0, nil, &usize, &uid) == noErr, let uid else { return nil }
        return uid as String
    }

    /// A device's output volume (master, else channel 1), 0…1.
    private static func deviceVolume(_ dev: AudioObjectID) -> Float? {
        guard dev != 0 else { return nil }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                              mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var v: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        if AudioObjectHasProperty(dev, &addr),
           AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr { return v }
        addr.mElement = 1
        if AudioObjectHasProperty(dev, &addr),
           AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr { return v }
        return nil
    }

    /// Set a device's output volume (master if settable, else each channel).
    private static func setDeviceVolume(_ dev: AudioObjectID, _ value: Float) {
        guard dev != 0 else { return }
        var v = max(0, min(1, value))
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                              mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(dev, &addr),
           AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue {
            AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float>.size), &v)
            return
        }
        for ch in [UInt32(1), UInt32(2)] {
            addr.mElement = ch
            var s: DarwinBoolean = false
            if AudioObjectHasProperty(dev, &addr),
               AudioObjectIsPropertySettable(dev, &addr, &s) == noErr, s.boolValue {
                AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float>.size), &v)
            }
        }
    }

    // MARK: Volume media keys

    private func installKeyTap() -> Bool {
        let mask = CGEventMask(1 << 14)   // NX_SYSDEFINED
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: swVolumeCallback, userInfo: refcon) else {
            Permissions.promptAccessibility()
            return false
        }
        keyTap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    fileprivate func reenable() { if let t = keyTap { CGEvent.tapEnable(tap: t, enable: true) } }

    fileprivate func handle(_ event: CGEvent) -> Bool {
        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }
        let keyCode = Int((ns.data1 & 0xFFFF0000) >> 16)
        guard keyCode == soundUp || keyCode == soundDown || keyCode == mute else { return false }
        if ((ns.data1 & 0xFF00) >> 8) == 0x0A {   // key down
            MainActor.assumeIsolated {
                switch keyCode {
                case soundUp:   setVolume(volume + step, bop: true)
                case soundDown: setVolume(volume - step, bop: true)
                case mute:      muted.toggle(); feedback(bop: false)
                default:        break
                }
            }
        }
        return true   // swallow so macOS's own (dead) handling is skipped
    }

    // MARK: Volume + feedback (HUD, "bop", menu slider)

    private let hud = VolumeHUD()
    // The stock macOS volume-change "pock"; fall back to Pop if unavailable.
    private lazy var bopSound: NSSound? =
        NSSound(contentsOfFile: "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff",
                byReference: true) ?? NSSound(named: "Pop")

    var currentVolume: Float { volume }
    var isMuted: Bool { muted }

    @MainActor func setVolumeFromMenu(_ v: Float) { setVolume(v, bop: false) }

    @MainActor
    private func setVolume(_ v: Float, bop: Bool) {
        muted = false
        volume = min(1, max(0, v))
        gain = Self.gain(for: volume)
        feedback(bop: bop)
    }

    @MainActor
    private func feedback(bop: Bool) {
        hud.show(level: volume, muted: muted)
        // Play the click at the new gain so it previews the actual loudness.
        if bop, !muted, let s = bopSound { s.stop(); s.volume = gain; s.play() }
    }
}

// MARK: - Volume HUD

private final class VolumeHUDModel: ObservableObject, @unchecked Sendable {
    @Published var level: Float = 1
    @Published var muted = false
}

/// A small on-screen volume overlay shown on the cursor's screen while adjusting.
private final class VolumeHUD: @unchecked Sendable {
    private var panel: NSPanel?
    private let model = VolumeHUDModel()
    private var hideTimer: Timer?

    @MainActor
    func show(level: Float, muted: Bool) {
        model.level = level
        model.muted = muted
        let p = panel ?? makePanel()
        panel = p
        position(p)
        p.orderFrontRegardless()
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak p] _ in p?.orderOut(nil) }
    }

    @MainActor
    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 54),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingView(rootView: VolumeHUDView(model: model))
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        return p
    }

    @MainActor
    private func position(_ p: NSPanel) {
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.frame
        let w: CGFloat = 220, h: CGFloat = 54
        p.setFrame(NSRect(x: f.midX - w / 2, y: f.minY + 120, width: w, height: h), display: true)
    }
}

private struct VolumeHUDView: View {
    @ObservedObject var model: VolumeHUDModel

    private var symbol: String {
        if model.muted { return "speaker.slash.fill" }
        if model.level < 0.01 { return "speaker.fill" }
        return model.level < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).frame(width: 22)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.2))
                    Capsule().fill(Color.primary.opacity(0.85))
                        .frame(width: max(0, geo.size.width * CGFloat(model.muted ? 0 : model.level)))
                }
            }
            .frame(height: 6)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassPanel(14)
    }
}

private func swVolumeCallback(proxy: CGEventTapProxy, type: CGEventType,
                              event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let me = Unmanaged<SoftwareVolumeFeature>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        me.reenable()
        return Unmanaged.passUnretained(event)
    }
    if me.handle(event) { return nil }
    return Unmanaged.passUnretained(event)
}
