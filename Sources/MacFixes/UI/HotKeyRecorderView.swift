import SwiftUI
import Carbon.HIToolbox
import AppKit

/// A labelled row that shows a hotkey and lets you re-record it.
struct HotKeyRow: View {
    let label: String
    let combo: KeyCombo
    let onChange: (KeyCombo) -> Void

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Button(recording ? "Press keys…" : combo.display) {
                recording ? stop() : record()
            }
            .frame(minWidth: 120)
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
        }
        .onDisappear { stop() }
    }

    private func record() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = Self.carbonFlags(event.modifierFlags)
            // Require at least one modifier so we don't grab plain typing.
            guard mods != 0 else { return event }
            onChange(KeyCombo(keyCode: UInt32(event.keyCode), modifiers: mods))
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    static func carbonFlags(_ ns: NSEvent.ModifierFlags) -> UInt32 {
        var f: UInt32 = 0
        if ns.contains(.command) { f |= UInt32(cmdKey) }
        if ns.contains(.option)  { f |= UInt32(optionKey) }
        if ns.contains(.control) { f |= UInt32(controlKey) }
        if ns.contains(.shift)   { f |= UInt32(shiftKey) }
        return f
    }
}
