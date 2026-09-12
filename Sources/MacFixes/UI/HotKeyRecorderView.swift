import SwiftUI
import Carbon.HIToolbox
import AppKit

/// A button that shows a hotkey and re-records it when clicked.
struct HotKeyButton: View {
    let combo: KeyCombo
    let onChange: (KeyCombo) -> Void

    @State private var recording = false
    @State private var monitor: Any?

    private var swapOn: Bool { UserDefaults.standard.bool(forKey: "kbSwap") }

    var body: some View {
        Button(recording ? "Press keys…" : combo.display(windowsStyle: swapOn)) {
            recording ? stop() : record()
        }
        .frame(minWidth: 120)
        .buttonStyle(.bordered)
        .tint(recording ? .accentColor : nil)
        .onDisappear { stop() }
    }

    private func record() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = HotKeyButton.carbonFlags(event.modifierFlags)
            // Function keys (F13 etc) are fine with no modifier; otherwise require one.
            let isFunctionKey = event.keyCode >= 0x60 && event.keyCode <= 0x6F
            guard mods != 0 || isFunctionKey else { return event }
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

/// An editable list of shortcuts for one action (add / remove / re-record).
struct HotKeyListEditor: View {
    let label: String
    let combos: [KeyCombo]
    let onChange: ([KeyCombo]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).fontWeight(.medium)
            ForEach(Array(combos.enumerated()), id: \.offset) { idx, combo in
                HStack {
                    HotKeyButton(combo: combo) { new in
                        var c = combos; c[idx] = new; onChange(c)
                    }
                    Button {
                        var c = combos; c.remove(at: idx); onChange(c)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(combos.count <= 1)
                    Spacer()
                }
            }
            Button {
                onChange(combos + [KeyCombo(keyCode: UInt32(kVK_F13),
                                            modifiers: UInt32(controlKey))])
            } label: {
                Label("Add shortcut", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
    }
}
