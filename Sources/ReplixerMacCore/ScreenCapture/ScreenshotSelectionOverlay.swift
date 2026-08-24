import AppKit
import Foundation

/// A full-screen region picker, invoked right before
/// `ScreenCaptureService.captureRegion` so the manager can mark exactly the
/// chat area to screenshot.
///
/// Windows parity source: `ScreenshotSelectionWindow.xaml`/`.cs` — but this
/// is **not** a port, it's a from-scratch macOS-native replacement (WPF's
/// `Canvas`+`Rectangle`+mouse-capture routed events have no AppKit
/// equivalent to translate line-by-line). Deliberately scoped down for mac's
/// v1: a single freehand drag-and-release gesture commits the selection
/// immediately on mouse-up — no resize handles, no confirm/cancel button
/// panel like Windows' `ScreenshotSelectionWindow` has. Escape still
/// cancels, same as Windows' `OnWindowKeyDown`.
public enum ScreenshotSelectionOverlay {
    // Keeps the controller (and, transitively, its window/view) alive for
    // the whole selection gesture. Without this, `select()`'s local
    // `controller` below has *no* strong references anywhere once `show()`
    // returns — AppKit does NOT retain a programmatically-created,
    // window-controller-less `NSWindow` just because it's on screen, unlike
    // e.g. a storyboard-owned window. ARC was deallocating `controller`
    // (and its stored `completion` closure, which holds the continuation)
    // essentially the instant `show()` returned, before the manager could
    // ever see or drag on the overlay — silently closing the window and
    // leaking the continuation forever. Symptom this was causing: the
    // "Швидкі дії" row's spinner never resolves (`select()`'s `Task` hangs
    // permanently) and the console logs Swift's runtime
    // "SWIFT TASK CONTINUATION MISUSE: select() leaked its continuation!"
    // warning.
    @MainActor
    private static var activeController: SelectionWindowController?

    /// Shows the overlay across every attached screen and suspends until the
    /// user releases the mouse after dragging a rectangle (returns the
    /// selected rect, in the same bottom-left-origin `NSScreen`/AppKit
    /// coordinate space `ScreenCaptureService.captureRegion` expects) or
    /// presses Escape to cancel, in which case this returns `nil`.
    @MainActor
    public static func select() async -> CGRect? {
        await withCheckedContinuation { continuation in
            let controller = SelectionWindowController { rect in
                activeController = nil
                continuation.resume(returning: rect)
            }
            activeController = controller
            controller.show()
        }
    }
}

/// Owns the overlay window's lifetime and guarantees the completion
/// callback fires exactly once (mirrors the "resume exactly once" contract
/// `CheckedContinuation` requires) — drag-release and Escape both funnel
/// through `finish(_:)`.
@MainActor
private final class SelectionWindowController {
    private var window: NSWindow?
    private var view: SelectionView?
    private let completion: (CGRect?) -> Void
    private var didComplete = false

    init(completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
    }

    func show() {
        // One borderless window spans the union of every screen (not just
        // `NSScreen.main`) so a manager on a multi-monitor setup can drag
        // across/onto a secondary display — mirrors capturing being
        // display-aware in `ScreenCaptureService.captureRegion`.
        let unionFrame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        guard !unionFrame.isNull, unionFrame.width > 0, unionFrame.height > 0 else {
            finish(nil)
            return
        }

        let window = OverlayWindow(
            contentRect: unionFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver // above everything, including the menu bar
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // NSPanel defaults this to true, which would hide the overlay the
        // instant ReplixerMac deactivates — exactly what can happen right
        // as this shows (the messenger app was just made frontmost by
        // `NSWorkspace.shared.open` a moment earlier in `captureAndUpload`).
        window.hidesOnDeactivate = false

        let view = SelectionView(frame: NSRect(origin: .zero, size: unionFrame.size))
        view.onFinish = { [weak self] localRect in
            guard let self else { return }
            guard let localRect else {
                self.finish(nil)
                return
            }
            // `localRect` is in the overlay view's own coordinate space —
            // re-base it onto the union frame's origin to get back to the
            // same global screen space `NSScreen.frame` (and thus
            // `ScreenCaptureService.captureRegion`) uses.
            let globalRect = localRect.offsetBy(dx: unionFrame.origin.x, dy: unionFrame.origin.y)
            self.finish(globalRect)
        }
        window.contentView = view

        // Deliberately NOT `NSApp.activate(ignoringOtherApps:)` — that would
        // activate the whole app, which raises *every* ReplixerMac window
        // (including the still-open MissedCallReportView sheet) above every
        // other app's windows, including the messenger this capture is
        // supposed to be screenshotting. `.nonactivatingPanel` lets this
        // specific window become key and receive the drag gesture / Escape
        // without touching app-wide activation or any other window's
        // z-order, so the messenger stays exactly where it was, visible
        // through the selection's "hole".
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)

        self.window = window
        self.view = view
    }

    private func finish(_ rect: CGRect?) {
        guard !didComplete else { return }
        didComplete = true
        window?.orderOut(nil)
        window = nil
        view = nil
        completion(rect)
    }
}

/// `NSPanel` rather than plain `NSWindow` so `.nonactivatingPanel` (used in
/// `show()`) is even available — that style is documented as panel-only,
/// AppKit silently drops it on a bare `NSWindow`. Borderless (panel or not)
/// windows also don't become key by default, which would silently swallow
/// the Escape-to-cancel `keyDown` — override both so `SelectionView`
/// actually receives keyboard events despite never being app-activated.
private final class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Draws the dim-screen-with-a-clear-cutout overlay and tracks a single
/// freehand drag gesture: mouse-down starts the rectangle, mouse-drag
/// resizes it live, mouse-up commits it immediately via `onFinish`.
private final class SelectionView: NSView {
    /// `nil` means cancelled (Escape), otherwise the committed rect in this
    /// view's own coordinate space.
    var onFinish: ((CGRect?) -> Void)?

    private var dragStart: CGPoint?
    private var currentRect: CGRect = .zero

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        guard currentRect.width > 0, currentRect.height > 0 else { return }

        // Punch a clear "hole" at the current drag rect so the manager can
        // see exactly what will be captured.
        NSColor.clear.setFill()
        currentRect.fill(using: .copy)

        NSColor.white.setStroke()
        let border = NSBezierPath(rect: currentRect)
        border.lineWidth = 2
        border.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        currentRect = CGRect(origin: point, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        currentRect = CGRect(
            x: min(start.x, point.x),
            y: min(start.y, point.y),
            width: abs(point.x - start.x),
            height: abs(point.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        guard currentRect.width > 2, currentRect.height > 2 else {
            // Too small to be an intentional selection — treat like a stray
            // click, not a commit; the manager can just drag again.
            currentRect = .zero
            needsDisplay = true
            return
        }
        onFinish?(currentRect)
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53 else { // Escape
            super.keyDown(with: event)
            return
        }
        onFinish?(nil)
    }
}
