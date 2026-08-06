import Foundation
import IOKit.hid
import AppKit

/// Swaps Left Control and Left Command system-wide via `hidutil`, so the
/// left-most modifier key — which is Control on both the built-in Mac keyboard
/// and a standard external PC keyboard — acts as Command. That gives Windows
/// muscle memory (Ctrl+C = copy, etc) at the HID level, before any app sees it.
///
/// hidutil mappings do not survive reboot and are not guaranteed to reach a
/// keyboard plugged in later, so this also installs a LaunchAgent (reapplies at
/// login) and reapplies on wake and whenever a keyboard is attached.
// Confined to the main run loop (setters, wake observer, IOKit callback all
// arrive there); the unchecked conformance reflects that.
final class ModifierSwap: @unchecked Sendable {
    private let agentLabel = "com.filipkin.macfixes.keyswap"

    // HID usage ids on the keyboard usage page (0x7 prefix).
    private let leftControl = 0x7000000E0
    private let leftCommand = 0x7000000E3

    private var hidManager: IOHIDManager?
    private var wakeObserver: NSObjectProtocol?

    private var agentPath: String {
        "\(NSHomeDirectory())/Library/LaunchAgents/\(agentLabel).plist"
    }

    var isEnabled: Bool { FileManager.default.fileExists(atPath: agentPath) }

    // MARK: Enable / disable

    func enable() {
        applyMapping()
        writeAgent()
        loadAgent()
        startWatching()
    }

    func disable() {
        stopWatching()
        unloadAgent()
        try? FileManager.default.removeItem(atPath: agentPath)
        clearMapping()
    }

    /// Reapply at launch if it should be on (LaunchAgent already covers login,
    /// this covers the app being (re)opened and starts the hot-plug watcher).
    func reapplyIfEnabled() {
        guard isEnabled else { return }
        applyMapping()
        startWatching()
    }

    // MARK: hidutil

    private var mappingJSON: String {
        "{\"UserKeyMapping\":["
        + "{\"HIDKeyboardModifierMappingSrc\":\(leftControl),\"HIDKeyboardModifierMappingDst\":\(leftCommand)},"
        + "{\"HIDKeyboardModifierMappingSrc\":\(leftCommand),\"HIDKeyboardModifierMappingDst\":\(leftControl)}"
        + "]}"
    }

    private func applyMapping() { run("/usr/bin/hidutil", ["property", "--set", mappingJSON]) }
    private func clearMapping() { run("/usr/bin/hidutil", ["property", "--set", "{\"UserKeyMapping\":[]}"]) }

    // MARK: LaunchAgent (persist across login)

    private func writeAgent() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(agentLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/hidutil</string>
                <string>property</string>
                <string>--set</string>
                <string>\(mappingJSON)</string>
            </array>
            <key>RunAtLoad</key><true/>
        </dict>
        </plist>
        """
        let dir = "\(NSHomeDirectory())/Library/LaunchAgents"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? plist.write(toFile: agentPath, atomically: true, encoding: .utf8)
    }

    private func loadAgent() { run("/bin/launchctl", ["load", "-w", agentPath]) }
    private func unloadAgent() { run("/bin/launchctl", ["unload", "-w", agentPath]) }

    // MARK: Reapply on wake / hot-plug

    private func startWatching() {
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.applyMapping()
            }
        }
        guard hidManager == nil else { return }
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                                    kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard]
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { context, _, _, _ in
            guard let context else { return }
            let me = Unmanaged<ModifierSwap>.fromOpaque(context).takeUnretainedValue()
            me.applyMapping()  // a keyboard was attached — reapply the mapping
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = mgr
    }

    private func stopWatching() {
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); wakeObserver = nil }
        if let mgr = hidManager {
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            hidManager = nil
        }
    }

    // MARK: Process helper

    private func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        do { try p.run(); p.waitUntilExit() }
        catch { NSLog("ModifierSwap \(path) failed: \(error)") }
    }
}
