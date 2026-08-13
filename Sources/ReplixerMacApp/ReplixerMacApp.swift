import SwiftUI
import AppKit
import ReplixerMacCore

/// Owns the app's runtime side: activation, and — since Phase 7.5 — the
/// actual call-detection/recording pipeline (`CallMonitor` +
/// `CallRecordingCoordinator` + `PendingUploadRetryService`), previously
/// only wired up in `ReplixerMacCallPoC/main.swift`. Until now
/// `ReplixerMacApp` was, per its own Phase 7.1 doc comment, "minimal SwiftUI
/// app shell, not yet wired up to ReplixerMacCore's functionality" — Phase
/// 7.5's HomeView needs a live "is a call being recorded right now" status
/// to show, which only exists if this app actually runs the pipeline
/// itself, not just displays data a separate CLI process happened to write
/// to disk. `ReplixerMacCallPoC` keeps its own copy of this wiring (it
/// remains useful as a UI-less runner/smoke-test harness) — the two aren't
/// meant to run at the same time against the same user, same as Windows
/// only ever running as a single instance.
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = CallRecordingCoordinator()
    private let monitor = CallMonitor()
    private lazy var pendingUploadRetryService = PendingUploadRetryService(coordinator: coordinator)
    // Phase 8.1: menu bar icon (Windows-parity: TrayViewModel's TaskbarIcon).
    // Held here, not as a local var in applicationDidFinishLaunching — an
    // NSStatusItem is removed from the menu bar as soon as its owning
    // object is deallocated, so it needs a strong reference for the whole
    // app lifetime, same reasoning as `coordinator`/`monitor` above.
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Phase 11.2: publish the running app's coordinator instance for
        // HomeView's manual start/stop button — see
        // CallRecordingCoordinator.appInstance's doc comment.
        CallRecordingCoordinator.appInstance = coordinator

        // Phase 8.3: `.accessory`, not `.regular` — matches Info.plist's
        // LSUIElement=true (menu-bar-only, no Dock icon/Cmd+Tab entry, see
        // StatusItemController). Explicit here rather than left to
        // Info.plist alone: this line used to hardcode `.regular` (pre-
        // Phase-8.3, before there was an Info.plist to read LSUIElement
        // from at all) specifically because SwiftPM executables launched
        // via Xcode's debugger don't get the automatic frontmost-activation
        // Finder-launched apps get for free — that reasoning still applies,
        // it just needs the accessory-compatible target now. Accessory apps
        // can still `.activate`/own a key window; they just don't reserve a
        // Dock slot.
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)

        statusItemController = StatusItemController()

        // Same startup sequence as ReplixerMacCallPoC/main.swift: sweep any
        // `.inprogress` file / dangling `.recording` history entry left by a
        // crash or force-quit on a previous run before doing anything else.
        FileNaming.cleanupStalePartialFiles()
        let reconciledCount = RecordingHistory.shared.reconcileDanglingRecordings()
        if reconciledCount > 0 {
            print("[ReplixerMacApp] ⚠️ Знайдено \(reconciledCount) запис(ів) історії, залишених у статусі \"recording\" після аварійного завершення — позначено як \"error\".")
        }

        // Phase 11.1: no longer a direct pass-through — CallMonitor's
        // detection now asks the user via CallConfirmRequestStore/
        // CallConfirmView before actually starting/stopping a recording.
        // Windows parity: HomeViewModel.OnCallDetected/OnCallEnded showing a
        // CallDialogViewModel first.
        //
        // Both closures below guard on two things before ever requesting a
        // dialog, matching OnCallDetected/OnCallEnded exactly:
        //   1. `isRecordingNow` — if a recording is already in flight, don't
        //      ask again. Needed because CallMonitor's mic+speaker heuristic
        //      can flicker (poll sees IO drop for a beat, fires onCallEnded,
        //      user picks "Продовжити запис" so the recording keeps going —
        //      but CallMonitor's own `activeMessenger` is already nil at
        //      that point, so the very next poll that sees IO active again
        //      reads as a *new* call and fires onCallStarted). Without this
        //      guard that re-fire popped the "Почати запис?" dialog back up
        //      mid-recording, which Windows never does
        //      (`if (_isRecording) { UpdatePlatform(app); if (!_hasActiveDialog) return; }`).
        //   2. `CallConfirmRequestStore.shared.pending == nil` — don't stack
        //      a second dialog request on top of one still awaiting an
        //      answer (Windows: `if (_hasActiveDialog) return;`). Otherwise
        //      the earlier request's continuation would be silently
        //      orphaned (see CallConfirmRequestStore.requestConfirmation's
        //      doc comment).
        monitor.onCallStarted = { [coordinator] messenger, name in
            Task {
                let alreadyRecording = await coordinator.isRecordingNow
                guard !alreadyRecording else { return }
                guard CallConfirmRequestStore.shared.pending == nil else { return }
                // Phase 11.3 — Windows parity: `ShowDialog`'s unconditional
                // `DismissCallReport(interrupted: true)` before ever showing
                // a new start/end confirm dialog. A no-op the vast majority
                // of the time (no report form open), but guarantees a report
                // form from a still-finishing earlier call never gets left
                // stranded behind a fresh confirm dialog on top of it.
                CallReportRequestStore.shared.interrupt()
                let confirmed = await CallConfirmRequestStore.shared.requestConfirmation(
                    kind: .start, platform: name)
                guard confirmed else { return }
                await coordinator.callStarted(messenger: messenger, processName: name)
            }
        }
        monitor.onCallEnded = { [coordinator] messenger, name in
            Task {
                // Nothing to confirm-stop if the matching "start recording?"
                // dialog for this call was answered "Пропустити" — Windows
                // parity: OnCallEnded's `if (!_isRecording) { DismissDialog(); return; }`.
                guard await coordinator.isRecordingNow else { return }
                guard CallConfirmRequestStore.shared.pending == nil else { return }
                // Phase 11.3 — same reasoning as onCallStarted above.
                CallReportRequestStore.shared.interrupt()
                let confirmed = await CallConfirmRequestStore.shared.requestConfirmation(
                    kind: .end, platform: name, recordingStartedAt: RecordingStatusStore.shared.status.startedAt)
                guard confirmed else { return }
                await coordinator.callEnded(messenger: messenger, processName: name)
            }
        }
        monitor.start()
        pendingUploadRetryService.start()
    }

    /// AppKit's async-shutdown hook: returning `.terminateLater` and calling
    /// `NSApp.reply(toApplicationShouldTerminate:)` once cleanup finishes
    /// lets Cmd+Q/Dock-quit wait for an in-flight recording to be finalized
    /// (renamed from `.inprogress`) and pending settings/history writes to
    /// flush — same intent as main.swift's SIGINT/SIGTERM handlers, adapted
    /// to how a real (non-CLI) macOS app actually gets asked to quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        pendingUploadRetryService.stop()
        Task { [coordinator] in
            await coordinator.shutdown()
            AppSettings.shared.flush()
            RecordingHistory.shared.flush()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct ReplixerMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 700, minHeight: 450)
        }
    }
}
