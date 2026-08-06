# Filip's Mac Fixes

A small, free, open-source menu-bar app that fixes the things about macOS that
annoy me. Every fix is an independent toggle; nothing runs unless you turn it
on. Built for macOS 26 (Tahoe) on Apple Silicon.

It exists because good tools for these fixes are either paid (mac-mouse-fix,
Shottr) or do far more than I need. This does only what I use.

## Fixes

Shipped:

- **Scroll** — inverts a physical mouse wheel while leaving the trackpad
  natural. macOS only has one system-wide "natural scrolling" switch; keep it
  ON and this inverts only the mouse (detected as non-continuous scroll).
- **Screenshots** — area capture to clipboard or file, and window capture,
  behind global hotkeys. Wraps the built-in `screencapture`.
- **System tweaks** — one-button toggles that wrap `defaults write`, each with
  a reset to the macOS default: instant Dock, scale minimize, no window
  animations, Finder hidden files / all extensions, fast key repeat, disable
  press-and-hold accents.

Planned (see the roadmap below):

- **Keyboard** — Windows-style muscle memory: `Ctrl+C/V/Z/S` etc, `Home`/`End`,
  `Ctrl+Arrow` word jumps, consistent across the built-in and external
  keyboards; tap the bottom-left key to open a launcher.
- **Windows** — Rectangle-style snapping and maximize, red-X quits the last
  window, best-effort "green button maximizes instead of full screen".
- **Screen recording** — record a selected area to MP4 or GIF.

## Build and install

Requires the Swift toolchain (Xcode or Command Line Tools).

```
./build.sh
open "/Applications/Filip's Mac Fixes.app"
```

`build.sh` compiles a release build, assembles the `.app`, ad-hoc signs it, and
installs it to `/Applications`. The app is a menu-bar item with no Dock icon.

## Permissions

The app is unsandboxed (event taps and window control require it) and ad-hoc
signed, so macOS will ask you to approve it. Grant these in
**System Settings → Privacy & Security** (the app's Permissions pane links
straight to each):

- **Accessibility** — scroll fix, window management, keyboard remaps.
- **Input Monitoring** — keyboard remapping and tap-to-launch.
- **Screen Recording** — screenshots and screen recording.

## Honest limitations

- The green traffic-light button cannot be cleanly intercepted (no public API);
  the window fix uses a best-effort "catch full screen, pull back to maximized"
  that some apps ignore.
- GIF export will use the built-in encoder (256 colours, no ffmpeg): good
  enough, not studio quality.

## Licence

MIT. See [LICENSE](LICENSE).
