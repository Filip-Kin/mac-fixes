import AppKit
import CoreGraphics

/// Drag the shared edge between two adjacent windows to resize both.
///
/// A mouse event tap watches for a left-click that lands on the seam between two
/// touching windows (with enough overlap along that edge). If found, it consumes
/// the click and, as the mouse drags, moves the divider — growing one window and
/// shrinking the other. Works for side-by-side (vertical seam) and stacked
/// (horizontal seam) pairs.
final class SeamResizer: @unchecked Sendable {
    private var tap: CFMachPort?

    fileprivate var resizing = false
    fileprivate var vertical = true
    fileprivate var winA: AXUIElement?   // left (vertical) or top (horizontal)
    fileprivate var winB: AXUIElement?   // right or bottom
    fileprivate var frameA0: CGRect = .zero
    fileprivate var frameB0: CGRect = .zero
    private var previewWin: NSWindow?
    private var lastDivider: CGFloat = 0

    private let seamTolerance: CGFloat = 12   // how close two edges count as touching
    private let grab: CGFloat = 8             // how close the click must be to the seam
    private let minOverlap: CGFloat = 80      // min shared length along the edge
    private let minSize: CGFloat = 120        // smallest a window can be squeezed to

    // MARK: Lifecycle

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: seamCallback,
                                          userInfo: refcon) else {
            return false
        }
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
        resizing = false
        hidePreview()
    }

    fileprivate func reenable() { if let tap { CGEvent.tapEnable(tap: tap, enable: true) } }

    // MARK: Drag handling (cursor is in global top-left coords == AX coords)

    /// Returns true if a seam was grabbed (and the click should be consumed).
    fileprivate func begin(at cursor: CGPoint) -> Bool {
        guard let seam = detectSeam(at: cursor),
              let a = AXWindow.window(matchingFrame: seam.a),
              let b = AXWindow.window(matchingFrame: seam.b) else { return false }
        vertical = seam.vertical
        winA = a; winB = b
        frameA0 = seam.a; frameB0 = seam.b
        resizing = true
        lastDivider = clampDivider(vertical ? cursor.x : cursor.y)
        showPreview(previewRect(lastDivider))
        return true
    }

    /// During the drag only move a preview line — resizing a heavy app (VSCode)
    /// on every event stalls the tap and the seam lags behind the cursor.
    fileprivate func update(to cursor: CGPoint) {
        guard resizing else { return }
        lastDivider = clampDivider(vertical ? cursor.x : cursor.y)
        showPreview(previewRect(lastDivider))
    }

    /// Apply the resize once, on release.
    fileprivate func end() {
        hidePreview()
        if let a = winA, let b = winB {
            if vertical {
                AXWindow.setFrame(a, CGRect(x: frameA0.minX, y: frameA0.minY,
                                            width: lastDivider - frameA0.minX, height: frameA0.height))
                AXWindow.setFrame(b, CGRect(x: lastDivider, y: frameB0.minY,
                                            width: frameB0.maxX - lastDivider, height: frameB0.height))
            } else {
                AXWindow.setFrame(a, CGRect(x: frameA0.minX, y: frameA0.minY,
                                            width: frameA0.width, height: lastDivider - frameA0.minY))
                AXWindow.setFrame(b, CGRect(x: frameB0.minX, y: lastDivider,
                                            width: frameB0.width, height: frameB0.maxY - lastDivider))
            }
        }
        resizing = false; winA = nil; winB = nil
    }

    private func clampDivider(_ v: CGFloat) -> CGFloat {
        vertical ? min(max(v, frameA0.minX + minSize), frameB0.maxX - minSize)
                 : min(max(v, frameA0.minY + minSize), frameB0.maxY - minSize)
    }

    /// The preview line rect in AX (top-left) coords, spanning the shared edge.
    private func previewRect(_ divider: CGFloat) -> CGRect {
        if vertical {
            let top = max(frameA0.minY, frameB0.minY), bottom = min(frameA0.maxY, frameB0.maxY)
            return CGRect(x: divider - 2, y: top, width: 4, height: bottom - top)
        } else {
            let left = max(frameA0.minX, frameB0.minX), right = min(frameA0.maxX, frameB0.maxX)
            return CGRect(x: left, y: divider - 2, width: right - left, height: 4)
        }
    }

    // Tap callbacks run on the main run loop, so touching AppKit here is safe.
    private func showPreview(_ axRect: CGRect) {
        MainActor.assumeIsolated {
            let rect = AXWindow.toBottomLeft(axRect)
            if previewWin == nil {
                let w = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
                w.isOpaque = false; w.backgroundColor = .clear; w.ignoresMouseEvents = true
                w.level = .floating; w.hasShadow = false
                w.contentView?.wantsLayer = true
                w.contentView?.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
                w.contentView?.layer?.cornerRadius = 2
                previewWin = w
            }
            previewWin?.setFrame(rect, display: true)
            previewWin?.orderFront(nil)
        }
    }

    private func hidePreview() {
        MainActor.assumeIsolated { previewWin?.orderOut(nil) }
    }

    private func detectSeam(at cursor: CGPoint) -> (vertical: Bool, a: CGRect, b: CGRect)? {
        let all = CGRect(x: -100_000, y: -100_000, width: 200_000, height: 200_000)
        let frames = AXWindow.onScreenWindowFrames(excluding: nil, intersecting: all)
        for a in frames {
            for b in frames where a != b {
                // Vertical seam: a on the left, b on the right, edges touching.
                if abs(a.maxX - b.minX) <= seamTolerance {
                    let top = max(a.minY, b.minY), bottom = min(a.maxY, b.maxY)
                    let seamX = (a.maxX + b.minX) / 2
                    if bottom - top > minOverlap, abs(cursor.x - seamX) <= grab,
                       cursor.y > top, cursor.y < bottom {
                        return (true, a, b)
                    }
                }
                // Horizontal seam: a on top, b below.
                if abs(a.maxY - b.minY) <= seamTolerance {
                    let left = max(a.minX, b.minX), right = min(a.maxX, b.maxX)
                    let seamY = (a.maxY + b.minY) / 2
                    if right - left > minOverlap, abs(cursor.y - seamY) <= grab,
                       cursor.x > left, cursor.x < right {
                        return (false, a, b)
                    }
                }
            }
        }
        return nil
    }
}

private func seamCallback(proxy: CGEventTapProxy,
                          type: CGEventType,
                          event: CGEvent,
                          refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let me = Unmanaged<SeamResizer>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        me.reenable()
        return Unmanaged.passUnretained(event)
    }

    switch type {
    case .leftMouseDown:
        if me.begin(at: event.location) { return nil }        // grabbed a seam — consume
    case .leftMouseDragged:
        if me.resizing { me.update(to: event.location); return nil }
    case .leftMouseUp:
        if me.resizing { me.end(); return nil }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}
