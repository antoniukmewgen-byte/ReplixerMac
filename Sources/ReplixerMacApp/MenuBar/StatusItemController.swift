import AppKit
import Sparkle
import ReplixerMacCore

/// Phase 8.1 — menu bar presence. Windows-parity source: `TrayViewModel` +
/// `TrayResources.xaml` (`hardcodet.net` `TaskbarIcon`), but still scoped
/// down: Windows' tray menu has a `RecordCommand` that manually
/// starts/stops recording (`HomeViewModel.ManualStartRecording/
/// ManualStopRecording`). That control now exists on mac too (Phase 11.2,
/// see `HomeView`'s manual start/stop button and
/// `CallRecordingCoordinator.manualStart()`/`manualStop()`) — it's just not
/// mirrored into this menu yet; the status line below stays read-only
/// display for now rather than a `RecordCommand`-style toggle. Worth
/// revisiting if manual control turns out to be needed without opening the
/// main window first.
///
/// Same "local mirror of a lock-protected snapshot, refreshed via
/// `NotificationCenter`" pattern `HomeView` already uses for
/// `RecordingStatusStore` — this controller isn't a SwiftUI view, so it
/// can't `@State`/`.onReceive`; it registers a plain observer instead and
/// tears it down in `deinit`.
final class StatusItemController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusLabelItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var observer: NSObjectProtocol?

    // Phase 13.2: held so `worldClockItem`'s action can call
    // `toggle()` on it — same "controller passed in, this class just wires
    // a menu item to it" shape as `updaterController` below, not a second
    // instance of its own.
    private let worldClockController: WorldClockWindowController

    /// Phase 9: `init()` is now `init(updaterController:)` — the one extra
    /// call site (`ReplixerMacApp.swift`'s `AppDelegate`) already owns the
    /// `SPUStandardUpdaterController` for the app's whole lifetime, so this
    /// menu just needs a reference to hang a "Перевірити оновлення…" item's
    /// target/action off of, not a second instance of its own. Phase 13.2
    /// adds `worldClockController` alongside it for the same reason.
    init(updaterController: SPUStandardUpdaterController, worldClockController: WorldClockWindowController) {
        self.worldClockController = worldClockController

        statusItem.button?.image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "ReplixerMac"
        )

        let menu = NSMenu()

        statusLabelItem.isEnabled = false
        menu.addItem(statusLabelItem)
        menu.addItem(.separator())

        let openItem = NSMenuItem(title: "Відкрити ReplixerMac", action: #selector(openMainWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        // Phase 13.2 — Windows parity: `TrayViewModel.WorldClockCommand`.
        // A plain toggle, same as Windows' tray item (no checkmark state
        // tracked here — WorldClockWindowController itself is the single
        // source of truth for whether the panel is currently open).
        let worldClockItem = NSMenuItem(title: "Світовий годинник", action: #selector(toggleWorldClock), keyEquivalent: "")
        worldClockItem.target = self
        menu.addItem(worldClockItem)

        // Phase 9 — wired directly to SPUStandardUpdaterController's own
        // `checkForUpdates(_:)` action method (the same selector Xcode-based
        // apps connect an IB menu item to), not a closure of our own — it
        // already does the right thing (shows Sparkle's standard "checking…"
        // / "up to date" / "update available" UI), so there's nothing for
        // this class to mediate.
        let updateItem = NSMenuItem(
            title: "Перевірити оновлення…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = updaterController
        // No paid Apple Developer ID yet (see Scripts/release.sh's header
        // comment) — every downloaded update is ad-hoc signed, so Gatekeeper
        // blocks its first launch until the user manually approves it via
        // System Settings. Sparkle's own "update available" dialog already
        // surfaces the same explanation as release notes (release.sh's
        // GATEKEEPER_NOTE), but this tooltip covers the person who just
        // clicks this menu item directly without reading that dialog.
        updateItem.toolTip = "Після встановлення нової версії, якщо застосунок не відкриється сам: Системні налаштування → Конфіденційність і безпека → «Все одно відкрити»."
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Вийти", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        render(RecordingStatusStore.shared.status)
        observer = NotificationCenter.default.addObserver(
            forName: RecordingStatusStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.render(RecordingStatusStore.shared.status)
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func render(_ status: RecordingStatusStore.Status) {
        if status.isRecording {
            statusLabelItem.title = "● Йде запис — \(status.platform ?? "дзвінок")"
            statusItem.button?.contentTintColor = .systemRed
        } else {
            statusLabelItem.title = "Очікую дзвінок..."
            statusItem.button?.contentTintColor = nil
        }
    }

    @objc private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // No window-id bookkeeping needed — WindowGroup only ever creates
        // one window for this app (no multi-window/document support), so
        // "the first window" is unambiguous. If the user closed it, this
        // brings it back the same way clicking the Dock icon would.
        if let window = NSApp.windows.first {
            // `makeKeyAndOrderFront` alone doesn't undo miniaturization
            // (Dock genie-effect state) — a separate AppKit window state
            // from front/back ordering. Same fix, same reasoning as
            // ContentView.refreshActiveCallSheet()'s doc comment.
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func toggleWorldClock() {
        worldClockController.toggle()
    }

    @objc private func quit() {
        // Routes through the same NSApplicationDelegate.applicationShouldTerminate
        // path as Cmd+Q/Dock-quit (AppDelegate in ReplixerMacApp.swift) — the
        // in-flight-recording flush/finalize logic there applies here too,
        // not just to the window-based quit paths.
        NSApp.terminate(nil)
    }
}
