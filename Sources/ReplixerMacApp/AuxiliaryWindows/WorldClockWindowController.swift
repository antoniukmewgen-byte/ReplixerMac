import AppKit
import SwiftUI

/// Phase 13.2 — owns the floating world-clock panel's show/hide/toggle
/// lifecycle. Windows parity source: `WindowManager.ToggleWorldClock()` —
/// single instance, opened/closed from the tray/status-item menu
/// (`StatusItemController`'s "Світовий годинник" item), rebuilt fresh each
/// time it's reopened since there's no state worth preserving between
/// opens (it's just a live clock).
final class WorldClockWindowController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?

    /// Called by `StatusItemController`'s menu item action.
    func toggle() {
        if let panel {
            // `windowWillClose` below clears `self.panel` — no need to do
            // it here too.
            panel.close()
            return
        }
        show()
    }

    private func show() {
        let hosting = NSHostingView(rootView: WorldClockView(onClose: { [weak self] in
            self?.panel?.close()
        }))
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.delegate = self

        let fittingSize = hosting.fittingSize
        var frame = NSRect(origin: .zero, size: fittingSize)
        // Top-left — same corner Windows' `WindowManager.ToggleWorldClock()`
        // uses (top-right is already the cheat sheet's spot).
        if let screenFrame = NSScreen.main?.visibleFrame {
            frame.origin = NSPoint(
                x: screenFrame.minX + 20,
                y: screenFrame.maxY - fittingSize.height - 20
            )
        }
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()

        self.panel = panel
    }

    /// Fires whether the panel was closed via the SwiftUI ✕ button
    /// (`WorldClockView.onClose` → `panel.close()`) or via `toggle()`
    /// above — clearing the reference here (not at each call site) means
    /// the next `toggle()` always sees accurate state, same as Windows'
    /// own `Closed` handler nulling `WindowManager`'s cached reference.
    func windowWillClose(_ notification: Notification) {
        panel = nil
    }
}
