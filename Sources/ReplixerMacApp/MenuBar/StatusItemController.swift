import AppKit
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

    init() {
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
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        // Routes through the same NSApplicationDelegate.applicationShouldTerminate
        // path as Cmd+Q/Dock-quit (AppDelegate in ReplixerMacApp.swift) — the
        // in-flight-recording flush/finalize logic there applies here too,
        // not just to the window-based quit paths.
        NSApp.terminate(nil)
    }
}
