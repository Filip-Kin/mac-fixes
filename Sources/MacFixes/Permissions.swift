import AppKit
import ApplicationServices
import CoreGraphics
import IOKit.hid
import Carbon
import ServiceManagement

/// Helpers for the TCC permissions the fixes rely on.
enum Permissions {

    // MARK: Accessibility (event taps that modify events, AX window control)

    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the system Accessibility prompt (adds the app to the pane).
    static func promptAccessibility() {
        // Literal avoids the non-Sendable global `kAXTrustedCheckOptionPrompt`.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    // MARK: Input Monitoring (event taps that listen to keys)

    static var hasInputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    @discardableResult
    static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    // MARK: Screen Recording (screenshots via screencapture, ScreenCaptureKit)

    static var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: Automation (Apple Events, sent via osascript)

    enum Status { case granted, denied, notAsked, unknown }

    /// Checks without prompting. `.unknown` when the target app is not
    /// running, since macOS only answers for a running target.
    static func automation(_ bundleID: String) -> Status {
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        guard AECreateDesc(typeApplicationBundleID, bytes, bytes.count, &target) == noErr else { return .unknown }
        defer { AEDisposeDesc(&target) }
        switch AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false) {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        default: return .unknown
        }
    }

    /// Sends a harmless Apple Event so macOS shows its consent prompt.
    static func requestAutomation(appName: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"\(appName)\" to get name"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// Launch System Events in the background so `automation` can answer
    /// for it (it is a faceless helper; osascript would start it anyway).
    static func launchSystemEvents(then done: @escaping @Sendable () -> Void) {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/System Events.app")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { done() }
        }
    }

    // MARK: Evidence-based (macOS has no API to read these)

    /// Set once a phone connection succeeds, which proves Local Network access.
    static let localNetworkProvenKey = "permLocalNetworkProven"
    /// true after a received file was saved to Downloads; false if saving failed.
    static let downloadsKey = "permDownloadsOK"

    static var localNetwork: Status {
        UserDefaults.standard.bool(forKey: localNetworkProvenKey) ? .granted : .notAsked
    }

    static var downloads: Status {
        guard let ok = UserDefaults.standard.object(forKey: downloadsKey) as? Bool else { return .notAsked }
        return ok ? .granted : .denied
    }

    // MARK: Login item

    static var loginItem: Status {
        switch SMAppService.mainApp.status {
        case .enabled: return .granted
        case .requiresApproval: return .denied
        case .notRegistered: return .notAsked
        default: return .unknown
        }
    }

    // MARK: Deep links to the relevant System Settings panes

    enum Pane: String {
        case accessibility = "Privacy_Accessibility"
        case inputMonitoring = "Privacy_ListenEvent"
        case screenRecording = "Privacy_ScreenCapture"
        case automation = "Privacy_Automation"
        case localNetwork = "Privacy_LocalNetwork"
        case filesAndFolders = "Privacy_FilesAndFolders"
    }

    static func openSettings(_ pane: Pane) {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
        NSWorkspace.shared.open(url)
    }

    static func openLoginItemsSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }

    static func openNotificationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }
}
