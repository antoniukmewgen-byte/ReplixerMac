import AppKit
import SwiftUI
import ReplixerMacCore

/// Phase 13.1 — owns the floating "cheat sheet" panel's lifecycle: shown
/// automatically when a call starts recording, hidden the moment it stops.
/// Windows parity source: `WindowManager.ShowCheatSheet()`/
/// `CloseCheatSheet()`, called directly from `HomeViewModel.StartRecording`/
/// `StopRecordingAsync`. Mac has no single call site shared across every
/// recording path (manual start, auto-detected start, and the confirm-
/// dialog path all funnel through the headless `CallRecordingCoordinator`
/// actor, which has no AppKit access to open a panel itself) — so instead
/// of a direct call, this mirrors `RecordingStatusStore` the same way
/// `StatusItemController`'s red-dot status line does: a plain
/// `NotificationCenter` observer reacting to `isRecording` flipping.
///
/// A borderless `NSPanel` (not a SwiftUI `Window` scene or `.sheet`)
/// because it needs to float above every window on screen — including
/// whatever messenger app the manager is tabbed into during the call —
/// and SwiftUI's own window-presentation APIs only ever layer over this
/// app's own windows.
final class CheatSheetWindowController {
    private var panel: NSPanel?
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: RecordingStatusStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.sync(isRecording: RecordingStatusStore.shared.status.isRecording)
        }
        // Covers the (normally unreachable) case where a recording is
        // somehow already in progress the instant this controller is
        // constructed — AppDelegate builds this before the monitor/
        // coordinator pipeline can start anything, but costs nothing to
        // be defensive about.
        sync(isRecording: RecordingStatusStore.shared.status.isRecording)
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func sync(isRecording: Bool) {
        if isRecording {
            show()
        } else {
            hide()
        }
    }

    private func show() {
        // Already showing — a duplicate didChange notification (e.g. the
        // platform name updating mid-call) shouldn't tear down and rebuild
        // the panel, which would silently reset any in-progress checkbox
        // state for no reason.
        guard panel == nil else { return }

        let hosting = NSHostingView(rootView: CheatSheetView())
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Native AppKit shadow, not a SwiftUI `.shadow(...)` in
        // CheatSheetView — see WorldClockWindowController.show()'s doc
        // comment.
        panel.hasShadow = true
        // .floating, not .modalPanel/.mainMenu — stays above normal
        // windows (including other apps') without fighting system UI like
        // Spotlight or a real modal. Matches Windows' Topmost="True".
        panel.level = .floating
        // Lets the panel be dragged from any empty area of its own
        // content — no separate header-drag hit-testing code needed,
        // unlike Windows' `Header_MouseDown` → `DragMove()`.
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Recording can run for the entire length of a call regardless of
        // which app is frontmost — the cheat sheet must stay visible even
        // while this app itself is in the background.
        panel.hidesOnDeactivate = false

        let fittingSize = hosting.fittingSize
        var frame = NSRect(origin: .zero, size: fittingSize)
        // Top-right of the main screen — same corner Windows'
        // `WindowManager.ShowCheatSheet()` places it in.
        if let screenFrame = NSScreen.main?.visibleFrame {
            frame.origin = NSPoint(
                x: screenFrame.maxX - fittingSize.width - 20,
                y: screenFrame.maxY - fittingSize.height - 20
            )
        }
        panel.setFrame(frame, display: false)
        // orderFrontRegardless, not makeKeyAndOrderFront — never wants to
        // steal keyboard focus from whatever the manager is actually
        // working in (the messenger app, most likely) just because a call
        // started.
        panel.orderFrontRegardless()

        self.panel = panel
    }

    private func hide() {
        panel?.orderOut(nil)
        // Dropped, not just hidden — a fresh call should always start
        // with every step unchecked, same as Windows never persisting
        // checkbox state across calls. Rebuilding CheatSheetView from
        // scratch on the next `show()` is what makes that happen for free.
        panel = nil
    }
}
