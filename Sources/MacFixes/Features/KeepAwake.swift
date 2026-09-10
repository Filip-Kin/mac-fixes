import AppKit
import IOKit.pwr_mgt

extension Notification.Name {
    static let keepAwakeChanged = Notification.Name("MacFixes.keepAwakeChanged")
}

/// Menu-bar "keep awake": holds a power-management assertion so the display and
/// the Mac do not idle-sleep, for a fixed duration or until turned off. The
/// same thing `caffeinate -d` does, without a terminal window.
@MainActor
final class KeepAwake {
    static let durations: [(label: String, minutes: Int?)] = [
        ("30 minutes", 30), ("1 hour", 60), ("2 hours", 120), ("4 hours", 240),
        ("Until turned off", nil),
    ]

    private(set) var isActive = false
    /// When the assertion ends, or nil for "until turned off".
    private(set) var until: Date?
    /// The menu choice that is active (minutes, or nil for indefinite).
    private(set) var activeMinutes: Int??

    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?

    func start(minutes: Int?) {
        stop()
        var id: IOPMAssertionID = 0
        // Literal stands in for the non-Sendable kIOPMAssertionTypePreventUserIdleDisplaySleep.
        let result = IOPMAssertionCreateWithName("PreventUserIdleDisplaySleep" as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Filip's Mac Fixes: keep awake" as CFString,
                                                 &id)
        guard result == kIOReturnSuccess else {
            NSLog("KeepAwake: assertion failed (\(result))")
            return
        }
        assertion = id
        isActive = true
        activeMinutes = .some(minutes)
        if let minutes {
            until = Date().addingTimeInterval(TimeInterval(minutes) * 60)
            timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes) * 60, repeats: false) { _ in
                Task { @MainActor in KeepAwake.shared.stop() }
            }
        } else {
            until = nil
        }
        NotificationCenter.default.post(name: .keepAwakeChanged, object: nil)
    }

    func stop() {
        if isActive { IOPMAssertionRelease(assertion) }
        assertion = 0
        isActive = false
        until = nil
        activeMinutes = nil
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.post(name: .keepAwakeChanged, object: nil)
    }

    /// "Keep Awake", or "Keep Awake · 43 min left" / "Keep Awake · on".
    var menuTitle: String {
        guard isActive else { return "Keep Awake" }
        guard let until else { return "Keep Awake · on" }
        let mins = max(1, Int(until.timeIntervalSinceNow / 60 + 0.5))
        return mins >= 60 ? "Keep Awake · \(mins / 60) h \(mins % 60) min left" : "Keep Awake · \(mins) min left"
    }

    static let shared = KeepAwake()
    private init() {}
}
