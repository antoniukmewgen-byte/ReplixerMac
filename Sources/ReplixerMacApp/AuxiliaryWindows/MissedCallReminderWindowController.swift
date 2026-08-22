import AppKit
import SwiftUI

/// Windows parity: `WindowManager.ShowMissedCallReminder()` +
/// `MissedCallReminderWindow` — a static, topmost, undismissable startup
/// banner that lives for the whole app lifetime and carries no data of its
/// own (it doesn't read `MissedCallReportRequestStore`/`RecordingHistory` or
/// anything else — see `MissedCallReminderView`'s doc comment). Windows
/// deliberately has `ShowMissedCallReminder()` with no matching `Close...`
/// counterpart ("нічого в застосунку не може випадково прибрати
/// нагадування"); this controller mirrors that by exposing only `show()`,
/// never a `hide()`/`close()`.
///
/// A `static let shared` singleton, not instance-held by `AppDelegate` like
/// `CheatSheetWindowController`/`WorldClockWindowController` — those two
/// need per-instance state threaded in from elsewhere (a coordinator to
/// observe, an updater controller to hand to a menu item). This has none of
/// that (same "no injected dependencies, no DataContext at all" as Windows'
/// version), and `show()` needs to be reachable both from `AppDelegate
/// .applicationDidFinishLaunching` (setup already complete at launch) and
/// from `SetupWizardView`'s finish callback (setup just completed this run)
/// — a singleton avoids threading a reference through the view hierarchy
/// for what's otherwise a single one-off call from two places.
final class MissedCallReminderWindowController {
    static let shared = MissedCallReminderWindowController()

    private var panel: NSPanel?

    private init() {}

    /// Idempotent — matches Windows' `if (_missedCallReminder != null)
    /// return;` guard. Safe to call from both launch sites above without
    /// worrying about which one actually runs first.
    func show() {
        guard panel == nil else { return }

        let hosting = NSHostingView(rootView: MissedCallReminderView())
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Native AppKit shadow, not a SwiftUI `.shadow(...)` — same
        // reasoning as CheatSheetWindowController/WorldClockWindowController.
        panel.hasShadow = true
        // .floating — matches Windows' Topmost="True".
        panel.level = .floating
        // Windows parity: `Banner_MouseDown` → `DragMove()` — "можна
        // перетягнути, якщо заважає, але не можна закрити". AppKit's
        // built-in drag-by-background does the same job without a manual
        // mouse handler in the SwiftUI content.
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Reminder should stay visible even while this app itself is in the
        // background — same reasoning as the cheat sheet panel.
        panel.hidesOnDeactivate = false

        let fittingSize = hosting.fittingSize
        var frame = NSRect(origin: .zero, size: fittingSize)
        // Windows parity: horizontally centered on the primary screen,
        // Top=16 from the screen's top edge. `visibleFrame` (excludes the
        // menu bar), not `frame`, for the vertical placement — Windows has
        // no menu-bar-equivalent to dodge, but placing this against the raw
        // screen top on Mac would tuck it half-behind the menu bar.
        if let screenFrame = NSScreen.main?.visibleFrame {
            frame.origin = NSPoint(
                x: screenFrame.midX - fittingSize.width / 2,
                y: screenFrame.maxY - fittingSize.height - 16
            )
        }
        panel.setFrame(frame, display: false)
        // orderFrontRegardless, not makeKeyAndOrderFront — never steals
        // keyboard focus, same as the cheat sheet panel.
        panel.orderFrontRegardless()

        self.panel = panel
    }
}
