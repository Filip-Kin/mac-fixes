import Foundation
import IOKit.hid
import AppKit
@preconcurrency import UserNotifications

/// Per-keyboard modifier remapping via `hidutil`, for Windows muscle memory.
///
/// The corner key becomes Command (the copy/paste key) on every keyboard, but
/// the corner key differs by keyboard, so the mapping is per-device:
///
///  - External PC keyboards: Ctrl <-> Command, so the corner Ctrl acts as
///    Command and the Windows key acts as Control. Alt stays Option.
///  - Built-in MacBook keyboard (its corner is Fn): Fn -> Command, Ctrl stays
///    Control, Option -> Fn/Globe, Command -> Option.
///
/// Stacking rule: macOS applies the per-keyboard map from System Settings >
/// Keyboard > Modifier Keys first and the hidutil `UserKeyMapping` on top of
/// it. If both swap Ctrl and Command, the two cancel out and the keyboard
/// behaves as if unmapped. So an external keyboard that already has a
/// non-identity System Settings map is a *conflict*: its hidutil map is
/// cleared, the user is notified, and a Reset action deletes the System
/// Settings entry so this app can take over. The system only re-reads that
/// entry when the keyboard is attached, so after a reset the keyboard stays
/// hands-off until it is re-plugged (or the Mac restarts).
///
/// hidutil mappings do not survive reboot, so a LaunchAgent reapplies the
/// built-in mapping at login; the external ones are applied when the app
/// launches (see launch at login), on wake, and on keyboard hot-plug.
final class ModifierSwap: NSObject, ObservableObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let agentLabel = "com.filipkin.macfixes.keyswap"
    private let hidutil = "/usr/bin/hidutil"
    private let defaults = UserDefaults.standard

    // Match the internal keyboard by product name (it has no USB vendor/product id).
    private let builtinProduct = "Apple Internal Keyboard / Trackpad"
    private var builtinMatch: String { #"{"Product":"\#(builtinProduct)"}"# }

    // External keyboards: swap Left Control (E0) and Left Command / GUI (E3).
    private let externalMapping =
        #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x7000000E0,"HIDKeyboardModifierMappingDst":0x7000000E3},{"HIDKeyboardModifierMappingSrc":0x7000000E3,"HIDKeyboardModifierMappingDst":0x7000000E0}]}"#

    // Built-in: Fn(0xFF00000003)->Command(E3), Option(E2)->Fn, Command(E3)->Option(E2).
    private let builtinMapping =
        #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0xFF00000003,"HIDKeyboardModifierMappingDst":0x7000000E3},{"HIDKeyboardModifierMappingSrc":0x7000000E2,"HIDKeyboardModifierMappingDst":0xFF00000003},{"HIDKeyboardModifierMappingSrc":0x7000000E3,"HIDKeyboardModifierMappingDst":0x7000000E2}]}"#

    private let emptyMapping = #"{"UserKeyMapping":[]}"#

    private var hidManager: IOHIDManager?
    private var wakeObserver: NSObjectProtocol?
    private var pendingApply: DispatchWorkItem?
    private var notificationsReady = false

    /// External keyboards this app is not remapping, for the settings pane.
    @Published private(set) var conflicts: [Conflict] = []

    struct Conflict: Identifiable, Equatable {
        let id: String       // "<vendor>-<product>"
        let name: String
        /// Reset done; waiting for the keyboard to be re-plugged (or a restart).
        let awaitingReattach: Bool
    }

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
        publish([])
    }

    /// Reapply at launch if it should be on. Refreshes the LaunchAgent (in case
    /// the mapping changed in an update) and starts the hot-plug watcher.
    func reapplyIfEnabled() {
        guard isEnabled else { return }
        writeAgent()
        applyMapping()
        startWatching()
    }

    // MARK: Keyboards

    private struct Keyboard: Hashable {
        let vendor: Int
        let product: Int
        let name: String
        var id: String { "\(vendor)-\(product)" }
        var match: String { #"{"VendorID":\#(vendor),"ProductID":\#(product)}"# }
        var prefKey: String { "com.apple.keyboard.modifiermapping.\(vendor)-\(product)-0" }
    }

    private var lastAttached: [Keyboard] = []

    private func keyboard(from dev: IOHIDDevice) -> Keyboard? {
        let name = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? ""
        guard name != builtinProduct,
              let vendor = IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int,
              let product = IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int,
              vendor != 0 else { return nil }
        return Keyboard(vendor: vendor, product: product, name: name.isEmpty ? "Keyboard \(vendor):\(product)" : name)
    }

    private func attachedExternalKeyboards() -> [Keyboard] {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(mgr, keyboardMatch as CFDictionary)
        guard let devices = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else { return [] }
        var found = Set<Keyboard>()
        for dev in devices { if let kb = keyboard(from: dev) { found.insert(kb) } }
        return found.sorted { $0.name < $1.name }
    }

    private var keyboardMatch: [String: Any] {
        [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard]
    }

    // MARK: hidutil

    private func applyMapping() {
        // Drop any all-device mapping left by older versions so it cannot
        // stack with the per-device ones below or leak onto new keyboards.
        run(hidutil, ["property", "--set", emptyMapping])
        run(hidutil, ["property", "--matching", builtinMatch, "--set", builtinMapping])

        let attached = attachedExternalKeyboards()
        lastAttached = attached
        var found: [Conflict] = []
        for kb in attached {
            let awaiting = awaitingReattach.contains(kb.id)
            let systemMap = !awaiting && hasSystemSettingsModifierMap(kb)
            trace("\(kb.name) (\(kb.id)): \(awaiting ? "awaiting re-plug, hands off" : systemMap ? "System Settings map present, hands off" : "swap applied")")
            if awaiting {
                // Reset done, but the system still holds the old map in memory.
                run(hidutil, ["property", "--matching", kb.match, "--set", emptyMapping])
                found.append(Conflict(id: kb.id, name: kb.name, awaitingReattach: true))
            } else if systemMap {
                run(hidutil, ["property", "--matching", kb.match, "--set", emptyMapping])
                found.append(Conflict(id: kb.id, name: kb.name, awaitingReattach: false))
                notifyConflictOnce(kb)
            } else {
                run(hidutil, ["property", "--matching", kb.match, "--set", externalMapping])
                defaults.removeObject(forKey: notifiedKey(kb.id))
            }
        }
        publish(found)
    }

    private func clearMapping() {
        run(hidutil, ["property", "--set", emptyMapping])
        run(hidutil, ["property", "--matching", builtinMatch, "--set", emptyMapping])
        for kb in attachedExternalKeyboards() {
            run(hidutil, ["property", "--matching", kb.match, "--set", emptyMapping])
        }
    }

    /// Coalesces the burst of hot-plug callbacks a keyboard produces on attach.
    private func scheduleApply() {
        pendingApply?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyMapping() }
        pendingApply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func publish(_ list: [Conflict]) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.conflicts != list else { return }
            self.conflicts = list
        }
    }

    // MARK: System Settings modifier map (the conflict)

    /// True if System Settings > Keyboard > Modifier Keys has a non-identity
    /// mapping for this keyboard (stored per host as
    /// `com.apple.keyboard.modifiermapping.<vendor>-<product>-0`).
    private func hasSystemSettingsModifierMap(_ kb: Keyboard) -> Bool {
        // Read through `defaults`, the same way the value was written, and parse
        // the Src/Dst numbers textually. (CFPreferences returns the entries but
        // their CFNumber values do not bridge to NSNumber inside this app.)
        guard let text = output("/usr/bin/defaults", ["-currentHost", "read", "-g", kb.prefKey]) else {
            return false
        }
        let pairs = text.components(separatedBy: "}")
        var nonIdentity = false
        for chunk in pairs {
            let src = Self.number(after: "HIDKeyboardModifierMappingSrc", in: chunk)
            let dst = Self.number(after: "HIDKeyboardModifierMappingDst", in: chunk)
            if let src, let dst, src != dst { nonIdentity = true }
        }
        return nonIdentity
    }

    private static func number(after key: String, in text: String) -> Int64? {
        guard let r = text.range(of: key) else { return nil }
        let rest = text[r.upperBound...].drop { !$0.isNumber }
        return Int64(rest.prefix { $0.isNumber })
    }

    /// Runs a command and returns its stdout, or nil on a non-zero exit.
    private func output(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Deletes the System Settings map for that keyboard so this app can remap
    /// it. Takes effect when the keyboard is next attached (or after a restart).
    func resetSystemSettingsMap(_ conflict: Conflict) { resetSystemSettingsMap(id: conflict.id) }

    private func resetSystemSettingsMap(id: String) {
        guard let kb = lastAttached.first(where: { $0.id == id }) else { return }
        run("/usr/bin/defaults", ["-currentHost", "delete", "-g", kb.prefKey])
        var set = awaitingReattach
        set.insert(kb.id)
        awaitingReattach = set
        removedSinceReset.remove(kb.id)
        applyMapping()
        post(title: "Nearly there: re-plug \(kb.name)",
             body: "Its System Settings modifier map is reset. Unplug the keyboard and plug it back in (or restart) and Mac Fixes will take over the remap.",
             category: nil, userInfo: [:])
    }

    // Keyboards whose System Settings map was reset but that have not been
    // re-attached since. Cleared automatically after a restart (boot time changes).
    private var removedSinceReset = Set<String>()
    private var awaitingReattach: Set<String> {
        get {
            guard defaults.integer(forKey: "kbSwapAwaitingBoot") == bootTime() else { return [] }
            return Set(defaults.stringArray(forKey: "kbSwapAwaiting") ?? [])
        }
        set {
            defaults.set(Array(newValue).sorted(), forKey: "kbSwapAwaiting")
            defaults.set(bootTime(), forKey: "kbSwapAwaitingBoot")
        }
    }

    private func bootTime() -> Int {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return 0 }
        return Int(tv.tv_sec)
    }

    // MARK: Notifications

    private let conflictCategory = "kbSwapConflict"
    private let resetAction = "reset"
    private func notifiedKey(_ id: String) -> String { "kbSwapNotified.\(id)" }

    private func setupNotifications() {
        guard !notificationsReady, Bundle.main.bundleIdentifier != nil else { return }
        notificationsReady = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let reset = UNNotificationAction(identifier: resetAction, title: "Reset to default", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: conflictCategory, actions: [reset], intentIdentifiers: [])
        ])
    }

    private func notifyConflictOnce(_ kb: Keyboard) {
        guard !defaults.bool(forKey: notifiedKey(kb.id)) else { return }
        defaults.set(true, forKey: notifiedKey(kb.id))
        post(title: "\(kb.name) has its own modifier map",
             body: "System Settings › Keyboard › Modifier Keys already remaps this keyboard, so Mac Fixes is leaving it alone (the two would cancel out). Reset it to default to let Mac Fixes take over.",
             category: conflictCategory, userInfo: ["keyboard": kb.id])
    }

    private func post(title: String, body: String, category: String?, userInfo: [String: String]) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        setupNotifications()
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = userInfo
            if let category { content.categoryIdentifier = category }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == resetAction,
           let id = response.notification.request.content.userInfo["keyboard"] as? String {
            DispatchQueue.main.async { [weak self] in self?.resetSystemSettingsMap(id: id) }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // MARK: LaunchAgent (persist the built-in mapping across login)

    private var agentCommand: String {
        "\(hidutil) property --matching '\(builtinMatch)' --set '\(builtinMapping)'"
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
        setupNotifications()
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleApply()
            }
        }
        guard hidManager == nil else { return }
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(mgr, keyboardMatch as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { context, _, _, device in
            guard let context else { return }
            let me = Unmanaged<ModifierSwap>.fromOpaque(context).takeUnretainedValue()
            me.deviceAttached(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { context, _, _, device in
            guard let context else { return }
            let me = Unmanaged<ModifierSwap>.fromOpaque(context).takeUnretainedValue()
            me.deviceRemoved(device)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = mgr
    }

    private func deviceAttached(_ device: IOHIDDevice) {
        // A genuine re-plug (removal seen first) completes a pending reset:
        // the system has now read the deleted map, so this app can take over.
        if let kb = keyboard(from: device), removedSinceReset.contains(kb.id), awaitingReattach.contains(kb.id) {
            var set = awaitingReattach
            set.remove(kb.id)
            awaitingReattach = set
            removedSinceReset.remove(kb.id)
            post(title: "\(kb.name) is now remapped by Mac Fixes",
                 body: "Ctrl and Command are swapped the Windows way.", category: nil, userInfo: [:])
        }
        scheduleApply()
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        if let kb = keyboard(from: device) { removedSinceReset.insert(kb.id) }
    }

    private func stopWatching() {
        pendingApply?.cancel()
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); wakeObserver = nil }
        if let mgr = hidManager {
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            hidManager = nil
        }
    }

    private func trace(_ msg: String) { MacFixes.trace("ModifierSwap", msg) }

    // MARK: Process helper

    private func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() }
        catch { NSLog("ModifierSwap \(path) failed: \(error)") }
    }
}
