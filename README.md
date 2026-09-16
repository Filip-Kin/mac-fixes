# Filip's Mac Fixes

A small, free, open-source menu-bar app that fixes the things about macOS that
annoy me. Every fix is an independent toggle; nothing runs unless you turn it
on. Built for macOS 26–27 (Tahoe) on Apple Silicon.

It exists because good tools for these fixes are either paid (mac-mouse-fix,
Shottr) or do far more than I need. This does only what I use.

## Fixes

### Scroll

Inverts a physical mouse wheel while leaving the trackpad natural. macOS only
has one system-wide "natural scrolling" switch; keep it ON and this inverts only
the mouse (detected as a non-continuous scroll event).

### Clipboard history

The Windows `Win+V` thing. Everything you copy (text, images, files) is kept,
newest first, and `⌃V` opens a popup to search it and paste an entry back into
the app you were in. With the modifier swap on an external keyboard `⌃V` is the
physical `Win+V`. Content flagged as concealed or transient by the source app
(password managers, autofill) is never recorded, and recording pauses while a
known password manager is frontmost. Stored locally under
`~/Library/Application Support/Filip's Mac Fixes`. The popup also has UUID
(`⌘U`) and nanoid (`⌘N`) buttons that generate, copy and paste a fresh id.

### Keep awake

A menu-bar item that stops the display and the Mac from idle-sleeping for 30
minutes to 4 hours, or until turned off. The menu-bar icon turns into a cup
while it is on. The same as `caffeinate -d`, without the terminal window.

### Keyboard (Windows muscle memory)

- **Modifier swap** (persistent, per-device). Makes the corner key act as
  Command so `Ctrl+C/V/Z/S` work the Windows way on every keyboard. External
  keyboards swap `Ctrl` and `Command` (the Windows key becomes Control); the
  built-in keyboard runs a four-key cycle `Fn → Command`, `Command → Option`,
  `Option → Control`, `Control → Fn/Globe`, so the corner keys line up with a
  Windows laptop and the physical Control key becomes Fn/Globe (making
  `Fn+Arrow` act as Home / End / Page Up / Page Down). Applied at the
  HID level with `hidutil`, per keyboard, reapplied at login, on wake and on
  keyboard hot-plug. A keyboard that already has its own map in System
  Settings > Keyboard > Modifier Keys is left alone, because macOS stacks the
  two and two swaps cancel out; the app notifies you and offers a one-click
  reset of that entry (takes effect when the keyboard is re-plugged), after
  which it takes over. Decisions are logged to `~/Library/Logs/MacFixes.log`.
- **Text navigation.** `Home`/`End` jump to line start/end, `Ctrl+Arrow` jumps by
  word, `Ctrl+Home`/`End` to document top/bottom, `Ctrl+Backspace` deletes the
  previous word. Each rule is an independent toggle.
- **Windows shortcuts.** `Ctrl+Shift+Esc` opens Activity Monitor (handled by
  the event tap; the `⌘⇧Esc` form is accepted too because the external-keyboard
  swap turns the physical Ctrl key into Command).
- **Windows browser shortcuts.** Sets `F5` to refresh in every installed
  browser, written as a per-app shortcut (`NSUserKeyEquivalents`, the same
  mechanism as System Settings › Keyboard › Keyboard Shortcuts › App Shortcuts),
  so the browser handles the key itself. Safari also gets `Ctrl+F5` for a hard
  refresh; Edge cannot, because its normal and force-refresh menu items share
  the title "Refresh This Page" and per-app shortcuts key on the title (use
  `Ctrl+Shift+R`, which arrives as `⌘⇧R` on a swapped keyboard). `Ctrl+Shift+T`
  already reopens a closed tab on both keyboards, so it is not touched. Safari
  keeps its shortcuts in a protected container, so writing them needs Full Disk
  Access; the pane offers a button to grant it. Takes effect on the browser's
  next launch. Turning it off removes only the entries this app wrote.
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
- **Double-click the title bar to maximize** with the taskbar-aware fill instead
  of macOS zoom. An event tap swallows the double-click so the OS action never
  flashes first. Off by default.

### Taskbar

A Windows-style taskbar along the bottom of the screen showing open apps, so you
can see and switch what's running without a giant Dock. Click an icon to switch
(clicking the active app minimizes it); right-click to Pin, open a New Window, or
Quit; hover an app with several windows to pick one from live thumbnails; drag
icons to reorder (pinned order persists). Pinned apps stay on the bar even when
closed and launch on click. A Start button sits at the left, and Finder appears
as a File Explorer button that opens a fresh window on click (its indicator only
shows when it actually has a window open). Window snapping reserves the taskbar's
strip so windows stop above it. A clock sits on the right (system, 24-hour or ISO
format) and opens a calendar popup on click. Right-click empty space for Taskbar
settings. Optionally shows on every monitor. A separate switch hides the macOS
Dock entirely. Apple's auto-launched Tips app is hidden. Surfaces use macOS 26
Liquid Glass. Off by default.

### Start menu

Tap the Windows key on its own to open a launcher with Raycast-style fuzzy search
(acronyms like "vsc" find Visual Studio Code) across several sources: apps and
folders, common folders (Downloads, Documents…), System Settings panes (type
"wifi" or "displays" to jump straight there), Spotlight file search, and a
calculator (type an expression, Return copies the result). Results rank by how
often you launch them, so it sharpens over time. Arrow keys to move, Return to
run, Esc to close; a footer has System Settings, Sleep, Restart and Shut Down.
Opens on the cursor's screen and from the taskbar's Start button, and returns
focus to where you were when closed without launching. Off by default.

### Alt-Tab switcher

Hold Option (the physical Alt on a PC keyboard) and tap Tab to cycle every open
window as a centered grid of thumbnails; release Option to switch to the
highlighted one. Shift+Tab reverses, Esc cancels, clicking a thumbnail jumps to
it. Thumbnails are captured on demand and cached, and the overlay opens on the
screen under the cursor. Off by default.

### Window extras

Beyond snapping: double-click a title bar to maximize with the taskbar-aware fill
instead of macOS zoom (an event tap swallows the OS action so it doesn't flash).
The "Screen" screenshot and recording target the display holding the focused
window, not always the main one.

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

### Launch at login

On by default (toggle in the About pane). The external-keyboard modifier swap
is applied by the running app, so it needs to be up at login.

## Build and install

Requires Xcode. The standalone Command Line Tools (27.x) lack the SwiftUI macro
plugin, so `build.sh` uses Xcode's toolchain when it is installed.

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
