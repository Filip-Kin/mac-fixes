import Foundation
import Combine

/// One-button macOS tweaks that wrap `defaults write` / `killall`.
/// Each tweak can be applied and reset to the system default.
struct Tweak: Identifiable {
    let id: String
    let title: String
    let detail: String
    /// Commands to apply the tweak. Each is a full argv (e.g. ["defaults","write",...]).
    let applyCommands: [[String]]
    /// Commands to restore the default (usually `defaults delete`).
    let resetCommands: [[String]]
    /// Whether the change needs logout/relaunch to fully take effect.
    let needsRelogin: Bool
}

@MainActor
final class SystemTweaks: ObservableObject {
    /// Ids of tweaks we have applied (our own bookkeeping, for the UI toggle).
    @Published private(set) var applied: Set<String>

    private let defaults = UserDefaults.standard
    private let appliedKey = "appliedTweaks"

    init() {
        applied = Set(defaults.stringArray(forKey: "appliedTweaks") ?? [])
    }

    func isApplied(_ tweak: Tweak) -> Bool { applied.contains(tweak.id) }

    func apply(_ tweak: Tweak) {
        tweak.applyCommands.forEach(Self.run)
        applied.insert(tweak.id)
        persist()
    }

    func reset(_ tweak: Tweak) {
        tweak.resetCommands.forEach(Self.run)
        applied.remove(tweak.id)
        persist()
    }

    func toggle(_ tweak: Tweak) {
        isApplied(tweak) ? reset(tweak) : apply(tweak)
    }

    private func persist() {
        defaults.set(Array(applied), forKey: appliedKey)
    }

    private static func run(_ argv: [String]) {
        guard let first = argv.first else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [first] + argv.dropFirst()
        do { try p.run(); p.waitUntilExit() }
        catch { NSLog("tweak command failed (\(argv)): \(error)") }
    }

    // MARK: The curated catalogue

    static let all: [Tweak] = [
        Tweak(
            id: "dock-instant",
            title: "Dock: instant show/hide",
            detail: "Removes the auto-hide delay and speeds up the animation so the Dock appears the moment you hit the edge.",
            applyCommands: [
                ["defaults", "write", "com.apple.dock", "autohide-delay", "-float", "0"],
                ["defaults", "write", "com.apple.dock", "autohide-time-modifier", "-float", "0.4"],
                ["killall", "Dock"],
            ],
            resetCommands: [
                ["defaults", "delete", "com.apple.dock", "autohide-delay"],
                ["defaults", "delete", "com.apple.dock", "autohide-time-modifier"],
                ["killall", "Dock"],
            ],
            needsRelogin: false),

        Tweak(
            id: "dock-scale-minimize",
            title: "Dock: scale minimize effect",
            detail: "Uses the faster ‘scale’ minimize effect instead of the genie animation.",
            applyCommands: [
                ["defaults", "write", "com.apple.dock", "mineffect", "-string", "scale"],
                ["killall", "Dock"],
            ],
            resetCommands: [
                ["defaults", "delete", "com.apple.dock", "mineffect"],
                ["killall", "Dock"],
            ],
            needsRelogin: false),

        Tweak(
            id: "no-window-animations",
            title: "Disable window animations",
            detail: "Turns off the open/close/minimize window animations for a snappier feel.",
            applyCommands: [
                ["defaults", "write", "-g", "NSAutomaticWindowAnimationsEnabled", "-bool", "false"],
            ],
            resetCommands: [
                ["defaults", "delete", "-g", "NSAutomaticWindowAnimationsEnabled"],
            ],
            needsRelogin: true),

        Tweak(
            id: "finder-hidden-files",
            title: "Finder: show hidden files",
            detail: "Shows dotfiles and hidden system files in Finder.",
            applyCommands: [
                ["defaults", "write", "com.apple.finder", "AppleShowAllFiles", "-bool", "true"],
                ["killall", "Finder"],
            ],
            resetCommands: [
                ["defaults", "delete", "com.apple.finder", "AppleShowAllFiles"],
                ["killall", "Finder"],
            ],
            needsRelogin: false),

        Tweak(
            id: "finder-all-extensions",
            title: "Finder: show all file extensions",
            detail: "Always shows filename extensions.",
            applyCommands: [
                ["defaults", "write", "-g", "AppleShowAllExtensions", "-bool", "true"],
                ["killall", "Finder"],
            ],
            resetCommands: [
                ["defaults", "delete", "-g", "AppleShowAllExtensions"],
                ["killall", "Finder"],
            ],
            needsRelogin: false),

        Tweak(
            id: "fast-key-repeat",
            title: "Keyboard: fast key repeat",
            detail: "Sets a fast key-repeat rate and short delay (faster than the Settings slider allows).",
            applyCommands: [
                ["defaults", "write", "-g", "KeyRepeat", "-int", "2"],
                ["defaults", "write", "-g", "InitialKeyRepeat", "-int", "15"],
            ],
            resetCommands: [
                ["defaults", "delete", "-g", "KeyRepeat"],
                ["defaults", "delete", "-g", "InitialKeyRepeat"],
            ],
            needsRelogin: true),

        Tweak(
            id: "disable-press-and-hold",
            title: "Keyboard: disable press-and-hold accents",
            detail: "Disables the accent-character popup so holding a key repeats it instead.",
            applyCommands: [
                ["defaults", "write", "-g", "ApplePressAndHoldEnabled", "-bool", "false"],
            ],
            resetCommands: [
                ["defaults", "delete", "-g", "ApplePressAndHoldEnabled"],
            ],
            needsRelogin: true),
    ]
}
