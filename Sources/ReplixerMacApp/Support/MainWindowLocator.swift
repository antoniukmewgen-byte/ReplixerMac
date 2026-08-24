import AppKit

/// Finds "the" app-owned window that `StatusItemController.openMainWindow()`
/// and `ContentView.refreshActiveCallSheet()` mean when they say "the
/// one-and-only window" — `NSApp.windows` isn't actually scoped to windows
/// this app's SwiftUI `WindowGroup` created. It also includes AppKit-
/// internal windows (notably `NSStatusItem`'s private `NSStatusBarWindow`,
/// which backs the menu-bar icon) and every transient auxiliary panel this
/// app itself opens (the screenshot-selection overlay, the world clock
/// window, the cheat sheet, the missed-call reminder — all
/// `.nonactivatingPanel`), in no documented/guaranteed order.
///
/// Both call sites used to just take `NSApp.windows.first`, which could
/// occasionally grab the status bar's internal window instead of the real
/// content window — visible as AppKit's own logged warning: "-[NSWindow
/// makeKeyAndOrderFront:] called on NSStatusBarWindow ... which returned NO
/// from -[NSWindow canBecomeKeyWindow]". Harmless in practice (the call was
/// silently a no-op on that window either way — AppKit never let it become
/// key — so the visible behavior never actually broke), but still a sign the
/// lookup could grab the wrong window if enumeration order ever shifted.
///
/// A `WindowGroup`-created content window always has the standard titled/
/// closable/miniaturizable/resizable chrome; every other window this app
/// touches — status-bar-internal or one of its own auxiliary panels — is
/// `.borderless`. Filtering on `.titled` reliably picks out the real one
/// without needing any of those other windows' own code to cooperate.
extension NSApplication {
    var mainContentWindow: NSWindow? {
        windows.first { $0.styleMask.contains(.titled) }
    }
}
