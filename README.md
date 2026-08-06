# Filip's Mac Fixes

A small, free, open-source menu-bar app that fixes the things about macOS that
annoy me. Every fix is an independent toggle; nothing runs unless you turn it
on. Built for macOS 26 (Tahoe) on Apple Silicon.

It exists because good tools for these fixes are either paid (mac-mouse-fix,
Shottr) or do far more than I need. This does only what I use.

## Fixes

### Scroll

Inverts a physical mouse wheel while leaving the trackpad natural. macOS only
has one system-wide "natural scrolling" switch; keep it ON and this inverts only
the mouse (detected as a non-continuous scroll event).

### Keyboard (Windows muscle memory)

- **Modifier swap** (persistent, per-device). Makes the corner key act as
  Command so `Ctrl+C/V/Z/S` work the Windows way on every keyboard. External
  keyboards swap `Ctrl` and `Command` (the Windows key becomes Control); the
  built-in maps `Fn → Command`, `Option → Globe`, `Command → Option`, and leaves
  `Control` alone (so `Ctrl+C` still kills terminal processes). Applied at the
  HID level with `hidutil`, reapplied at login and on keyboard hot-plug.
- **Text navigation.** `Home`/`End` jump to line start/end, `Ctrl+Arrow` jumps by
  word, `Ctrl+Home`/`End` to document top/bottom, `Ctrl+Backspace` deletes the
  previous word. Each rule is an independent toggle.
- **Tap to launch.** Tap a chosen modifier key alone to fire a launcher shortcut
  (Spotlight by default). Off by default.

### Windows

- **Snap and maximize** with `Control+Option` shortcuts: halves (arrows),
  quarters (`U I J K`), maximize (`↩`), centre (`C`).
- **Adaptive drag-to-edge snapping.** Drag a window to an edge or corner to snap
  it, filling the space left by other windows. Enabling it turns off macOS's own
  edge-tiling so the two don't fight. Off by default.
- **Divider resize.** Drag the shared edge between two snapped windows to resize
  both at once.
- **Close quits the app.** When a regular app's last window closes, quit it
  (Windows-like). Finder is always left alone. Off by default.

### Screen capture

One pane covering screenshots and recording as a matrix of
Area / Window / Screen × Screenshot / Record MP4 / Record GIF. Each combination
can have its own shortcut and its own menu-bar item.

- Two global switches, **Save to file** and **Copy to clipboard**, apply to every
  capture. With "save to file" off, captures go to a temp folder so they can
  still be copied. Recordings copy the file to the clipboard (ready to paste into
  a chat); screenshots copy the image and the file.
- A configurable save location (defaults to `~/Documents/Mac Fixes`).
- While recording, a red border rings the captured area with Stop / Cancel
  buttons beside it; both sit outside the captured rectangle so they are not
  recorded.
- Screenshots wrap the built-in `screencapture`; recording uses ScreenCaptureKit
  into MP4 (`AVAssetWriter`, H.264) or GIF (ImageIO).

### System tweaks

One-button toggles that wrap `defaults write`, each with a reset to the macOS
default: instant Dock, scale minimize, no window animations, Finder hidden files
and all extensions, fast key repeat, disable press-and-hold accents, and F-keys
as standard function keys.

## Build and install

Requires the Swift toolchain (Xcode or Command Line Tools).

```
./setup-signing.sh   # once: creates a self-signed identity so permission grants survive rebuilds
./build.sh
open "/Applications/Filip's Mac Fixes.app"
```

`setup-signing.sh` is optional but recommended. Without it the app is ad-hoc
signed, and macOS forgets the Accessibility / Screen Recording grants every time
you rebuild, re-prompting you. The one-time setup asks for your login password
to trust the certificate.

`build.sh` compiles a release build, assembles the `.app`, signs it, and installs
it to `/Applications`. The app is a menu-bar item with no Dock icon.

## Permissions

The app is unsandboxed (event taps and window control require it), so macOS will
ask you to approve it. Grant these in **System Settings → Privacy & Security**
(the app's Permissions pane links straight to each):

- **Accessibility** — scroll, window management, keyboard remaps.
- **Input Monitoring** — keyboard remapping.
- **Screen Recording** — screenshots and screen recording.

## Honest limitations

- **Close-quits** reads window counts via Accessibility. A few apps (some
  Electron/Chromium ones) don't expose their windows, so it silently skips them.
- **Window recording** captures the frontmost window's current bounds, not an
  interactive picker. **Screen recording** targets the main display.
- **GIF** uses the built-in encoder (256 colours, no ffmpeg), downsized to 800px
  wide: good for short clips, not studio quality.
- **Tap-to-launch** can be unreliable on the Fn/Globe key on some hardware
  (the key emits an unbound press rather than a clean modifier), which is why
  it's off by default.

## Licence

MIT. See [LICENSE](LICENSE).
