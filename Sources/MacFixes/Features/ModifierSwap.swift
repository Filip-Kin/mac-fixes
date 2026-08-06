import Foundation
import IOKit.hid
import AppKit

/// Per-keyboard modifier remapping via `hidutil`, for Windows muscle memory.
///
/// The corner key becomes Command (the copy/paste key) on every keyboard, but
/// the corner key differs by keyboard, so the mapping is per-device:
///
///  - External PC keyboards (global mapping): Ctrl <-> Command, so the corner
///    Ctrl acts as Command and the Windows key acts as Control. Alt stays Option.
///  - Built-in MacBook keyboard (scoped override, since its corner is Fn):
///    Fn -> Command, Ctrl stays Control, Option -> Fn/Globe, Command -> Option.
///
/// Device-scoped hidutil mappings replace the global one for that device, so
/// the global mapping covers all external keyboards (present and future) while
/// the built-in gets its own. hidutil mappings do not survive reboot and may
/// not reach a keyboard plugged in later, so this also installs a LaunchAgent
/// (reapplies at login) and reapplies on wake and on keyboard hot-plug.
final class ModifierSwap: @unchecked Sendable {
    private let agentLabel = "com.filipkin.macfixes.keyswap"
    private let hidutil = "/usr/bin/hidutil"

    // Match the internal keyboard by product name (it has no USB vendor/product id).
    private let builtinMatch = #"{"Product":"Apple Internal Keyboard / Trackpad"}"#

    // External keyboards: swap Left Control (E0) and Left Command / GUI (E3).
    private let externalMapping =
        #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x7000000E0,"HIDKeyboardModifierMappingDst":0x7000000E3},{"HIDKeyboardModifierMappingSrc":0x7000000E3,"HIDKeyboardModifierMappingDst":0x7000000E0}]}"#

    // Built-in: Fn(0xFF00000003)->Command(E3), Option(E2)->Fn, Command(E3)->Option(E2).
    private let builtinMapping =
        #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0xFF00000003,"HIDKeyboardModifierMappingDst":0x7000000E3},{"HIDKeyboardModifierMappingSrc":0x7000000E2,"HIDKeyboardModifierMappingDst":0xFF00000003},{"HIDKeyboardModifierMappingSrc":0x7000000E3,"HIDKeyboardModifierMappingDst":0x7000000E2}]}"#

    private let emptyMapping = #"{"UserKeyMapping":[]}"#

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

    /// Reapply at launch if it should be on. Refreshes the LaunchAgent (in case
    /// the mapping changed in an update) and starts the hot-plug watcher.
    func reapplyIfEnabled() {
        guard isEnabled else { return }
        writeAgent()
        applyMapping()
        startWatching()
    }

    // MARK: hidutil

    private func applyMapping() {
        // Global first, then the built-in override (which wins for that device).
        run(hidutil, ["property", "--set", externalMapping])
        run(hidutil, ["property", "--matching", builtinMatch, "--set", builtinMapping])
    }

    private func clearMapping() {
        run(hidutil, ["property", "--set", emptyMapping])
        run(hidutil, ["property", "--matching", builtinMatch, "--set", emptyMapping])
    }

    // MARK: LaunchAgent (persist across login)

    private var agentCommand: String {
        "\(hidutil) property --set '\(externalMapping)' ; "
        + "\(hidutil) property --matching '\(builtinMatch)' --set '\(builtinMapping)'"
    }

    private func writeAgent() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(agentLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/bin/sh</string>
                <string>-c</string>
                <string>\(agentCommand)</string>
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
            me.applyMapping()  // a keyboard was attached — reapply the mappings
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
