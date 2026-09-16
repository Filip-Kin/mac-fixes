import AppKit
import CoreGraphics
import Carbon.HIToolbox

/// Windows-style keyboard behaviour.
///
/// Works with (and assumes) the Control/Command swap in `ModifierSwap`: after
/// the swap the left-most key sends Command, so "Ctrl+…" habits arrive here as
/// Command. This event tap then handles the chords that a single-key swap
/// cannot: text navigation and tap-a-modifier-to-launch.
final class KeyboardFeature: Feature, @unchecked Sendable {
    private var tap: CFMachPort?
    let modifierSwap = ModifierSwap()

    private let defaults = UserDefaults.standard

    // Cached config, refreshed from UserDefaults via reloadConfig().
    fileprivate var homeEnd = true
    fileprivate var wordJump = true
    fileprivate var docNav = true
    fileprivate var wordDelete = true
    fileprivate var tapToLaunch = true
    fileprivate var launcher = KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey))
    fileprivate var trigger: LaunchTrigger = .command
    fileprivate var taskManager = true

    /// Which modifier, tapped alone, fires the launcher.
    enum LaunchTrigger: String, CaseIterable, Identifiable {
        case command, control, option, shift, globe
        var id: String { rawValue }
        var label: String {
            switch self {
            case .command: return "Command / fn (⌘)"
            case .control: return "Control (⌃)"
            case .option:  return "Option (⌥)"
            case .shift:   return "Shift (⇧)"
            case .globe:   return "Globe (🌐)"
            }
        }

        /// Windows-keyboard names, used when the Windows-style swap is on.
        func label(windowsStyle: Bool) -> String {
            guard windowsStyle else { return label }
            switch self {
            case .command: return "Ctrl (⌘)"
            case .control: return "Control (⌃)"
            case .option:  return "Alt (⌥)"
            case .shift:   return "Shift (⇧)"
            case .globe:   return "Windows key (🌐)"
            }
        }
        var mask: CGEventFlags {
            switch self {
            case .command: return .maskCommand
            case .control: return .maskControl
            case .option:  return .maskAlternate
            case .shift:   return .maskShift
            case .globe:   return .maskSecondaryFn
            }
        }
    }

    // Tap-to-launch state (touched only on the tap's run loop).
    fileprivate var candidate = false
    fileprivate var sawOther = false
    fileprivate var candidateAt: TimeInterval = 0

    init() { reloadConfig() }

    // MARK: Persisted config

    var swapModifiers: Bool {
        get { defaults.object(forKey: "kbSwap") as? Bool ?? false }
        set {
            defaults.set(newValue, forKey: "kbSwap")
            newValue ? modifierSwap.enable() : modifierSwap.disable()
        }
    }
    var homeEndEnabled: Bool  { get { flag("kbHomeEnd") } set { setFlag("kbHomeEnd", newValue) } }
    var wordJumpEnabled: Bool { get { flag("kbWordJump") } set { setFlag("kbWordJump", newValue) } }
    var docNavEnabled: Bool   { get { flag("kbDocNav") } set { setFlag("kbDocNav", newValue) } }
    var wordDeleteEnabled: Bool { get { flag("kbWordDelete") } set { setFlag("kbWordDelete", newValue) } }
    // Off by default (fn/Globe tap detection is unreliable on some hardware).
    var tapToLaunchEnabled: Bool {
        get { defaults.object(forKey: "kbTapLaunch") as? Bool ?? false }
        set { setFlag("kbTapLaunch", newValue) }
    }

    var taskManagerEnabled: Bool { get { flag("kbTaskManager") } set { setFlag("kbTaskManager", newValue) } }

    var launchTrigger: LaunchTrigger {
        get { LaunchTrigger(rawValue: defaults.string(forKey: "kbLaunchTrigger") ?? "") ?? .command }
        set { defaults.set(newValue.rawValue, forKey: "kbLaunchTrigger"); reloadConfig() }
    }

    var launcherCombo: KeyCombo {
        get {
            if let data = defaults.data(forKey: "kbLauncher"),
               let c = try? JSONDecoder().decode(KeyCombo.self, from: data) { return c }
            return KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey))
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: "kbLauncher") }
            reloadConfig()
        }
    }

    private func flag(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
    private func setFlag(_ key: String, _ v: Bool) { defaults.set(v, forKey: key); reloadConfig() }

    func reloadConfig() {
        homeEnd = homeEndEnabled
        wordJump = wordJumpEnabled
        docNav = docNavEnabled
        wordDelete = wordDeleteEnabled
        tapToLaunch = tapToLaunchEnabled
        launcher = launcherCombo
        trigger = launchTrigger
        taskManager = taskManagerEnabled
    }

    // MARK: Feature lifecycle (the event tap)

    @discardableResult
    func start() -> Bool {
        modifierSwap.reapplyIfEnabled()
        reloadConfig()
        guard tap == nil else { return true }

        let mask = CGEventMask(
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue))
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: keyboardCallback,
                                          userInfo: refcon) else {
            trace("Keyboard", "event tap creation FAILED (AX trusted: \(AXIsProcessTrusted()))")
            Permissions.promptAccessibility()
            return false
        }
        trace("Keyboard", "event tap created (AX trusted: \(AXIsProcessTrusted()))")
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
        // Note: the persistent modifier swap is intentionally NOT undone here;
        // it is only removed when the user turns that toggle off.
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// What the tap should do with a key event.
    enum Outcome {
        case pass
        case swallow
        /// Replace with a fresh event carrying this key code and modifier set.
        case rewrite(code: Int, flags: CGEventFlags)
    }

    // MARK: Navigation remaps

    fileprivate func navRule(_ event: CGEvent) -> Outcome {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let cmd = flags.contains(.maskCommand)
        let base: CGEventFlags = flags.contains(.maskShift) ? .maskShift : []

        switch code {
        case kVK_Home where homeEnd:
            // Ctrl+Home -> document top. Plain Home -> line start in a text field,
            // otherwise pass through so the page scrolls to the top natively.
            if cmd && docNav { return .rewrite(code: kVK_UpArrow, flags: base.union(.maskCommand)) }
            return AXWindow.focusedIsTextInput()
                ? .rewrite(code: kVK_LeftArrow, flags: base.union(.maskCommand)) : .pass
        case kVK_End where homeEnd:
            if cmd && docNav { return .rewrite(code: kVK_DownArrow, flags: base.union(.maskCommand)) }
            return AXWindow.focusedIsTextInput()
                ? .rewrite(code: kVK_RightArrow, flags: base.union(.maskCommand)) : .pass
        case kVK_LeftArrow where cmd && wordJump:
            return .rewrite(code: kVK_LeftArrow, flags: base.union(.maskAlternate))
        case kVK_RightArrow where cmd && wordJump:
            return .rewrite(code: kVK_RightArrow, flags: base.union(.maskAlternate))
        case kVK_Delete where cmd && wordDelete:
            return .rewrite(code: kVK_Delete, flags: base.union(.maskAlternate))
        case kVK_ANSI_KeypadEnter:
            // Numpad Enter -> Return, so apps that ignore the keypad key fire.
            return .rewrite(code: kVK_Return,
                            flags: flags.intersection(KeyboardFeature.chordMask))
        default:
            return .pass
        }
    }

    // MARK: Windows shortcuts (task manager)

    /// Modifier bits that matter when matching a chord.
    private static let chordMask: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]

    fileprivate func windowsShortcut(_ event: CGEvent, keyDown: Bool) -> Outcome {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let mods = event.flags.intersection(KeyboardFeature.chordMask)

        // Ctrl+Shift+Esc → Activity Monitor. Also accept ⌘⇧Esc: with the
        // external-keyboard swap on, the physical Ctrl key arrives as Command.
        if taskManager, code == kVK_Escape,
           mods == [.maskControl, .maskShift] || mods == [.maskCommand, .maskShift] {
            if keyDown { openActivityMonitor() }
            return .swallow
        }
        return .pass
    }

    private func openActivityMonitor() {
        DispatchQueue.main.async {
            guard let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.ActivityMonitor") else { return }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
    }

    // MARK: Tap-a-modifier-to-launch

    fileprivate func handleFlags(_ event: CGEvent) {
        guard tapToLaunch else { return }
        let flags = event.flags
        let mask = trigger.mask
        let allMods: [CGEventFlags] = [.maskCommand, .maskShift, .maskControl,
                                       .maskAlternate, .maskSecondaryFn]
        let triggerDown = flags.contains(mask)
        let otherDown = allMods.contains { $0 != mask && flags.contains($0) }
        let onlyTrigger = triggerDown && !otherDown

        if triggerDown, onlyTrigger, !candidate {
            candidate = true
            sawOther = false
            candidateAt = ProcessInfo.processInfo.systemUptime
        } else if !triggerDown {
            if candidate, !sawOther,
               ProcessInfo.processInfo.systemUptime - candidateAt < 0.25 {
                postLauncher()
            }
            candidate = false
        } else {
            candidate = false  // another modifier joined; not a lone tap
        }
    }

    fileprivate func noteKey() { if candidate { sawOther = true } }

    private func postLauncher() {
        let src = CGEventSource(stateID: .hidSystemState)
        let code = CGKeyCode(launcher.keyCode)
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        down?.flags = launcher.cgFlags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        up?.flags = launcher.cgFlags
        up?.post(tap: .cghidEventTap)
    }
}

private func keyboardCallback(proxy: CGEventTapProxy,
                              type: CGEventType,
                              event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let feature = Unmanaged<KeyboardFeature>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        feature.reenable()
        return Unmanaged.passUnretained(event)
    }

    // The Globe/fn key emits its own key event (keycode 179 on this hardware)
    // in addition to the secondaryFn modifier. That key event is unbound and
    // beeps, so swallow it when Globe is the launch trigger. The launch itself
    // fires from the secondaryFn modifier in handleFlags.
    if (type == .keyDown || type == .keyUp),
       feature.tapToLaunch, feature.trigger == .globe,
       event.getIntegerValueField(.keyboardEventKeycode) == 179 {
        return nil
    }

    switch type {
    case .flagsChanged:
        feature.handleFlags(event)
    case .keyDown, .keyUp:
        feature.noteKey()
        var outcome = feature.windowsShortcut(event, keyDown: type == .keyDown)
        if case .pass = outcome { outcome = feature.navRule(event) }
        switch outcome {
        case .pass:
            break
        case .swallow:
            return nil
        case .rewrite(let code, let flags):
            // Since macOS 26.6.x the window server re-derives a hardware-backed
            // key event from its raw HID data after the tap stages run, so
            // editing the key code / flags in place no longer sticks. Replace
            // the event with a freshly built one instead (same fix as scroll).
            guard let replacement = CGEvent(keyboardEventSource: nil,
                                            virtualKey: CGKeyCode(code),
                                            keyDown: type == .keyDown) else { break }
            replacement.flags = flags
            replacement.timestamp = event.timestamp
            replacement.setIntegerValueField(.keyboardEventAutorepeat,
                                             value: event.getIntegerValueField(.keyboardEventAutorepeat))
            // The tap machinery releases the returned event; hand over our +1.
            return Unmanaged.passRetained(replacement)
        }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}
