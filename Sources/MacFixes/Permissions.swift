import AppKit
import ApplicationServices
import CoreGraphics
import IOKit.hid

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

    // MARK: Deep links to the relevant System Settings panes

    enum Pane: String {
        case accessibility = "Privacy_Accessibility"
        case inputMonitoring = "Privacy_ListenEvent"
        case screenRecording = "Privacy_ScreenCapture"
    }

    static func openSettings(_ pane: Pane) {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
        NSWorkspace.shared.open(url)
    }
}
