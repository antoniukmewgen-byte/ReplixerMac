import SwiftUI
import AppKit
import Sparkle
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
/// Windows parity: `UpdateService.cs` reports Sparkle-equivalent
/// (Squirrel/NetSparkle-style) update-check/download failures to the same
/// Telegram error channel every other operational failure goes to.
/// `SPUStandardUpdaterController` otherwise leaves failures entirely silent
/// on Mac — no delegate means Sparkle just logs to its own internal log and
/// gives up, with nothing surfacing to the developer.
private final class UpdaterErrorReporter: NSObject, SPUUpdaterDelegate {
    // Sparkle's own "no update found" outcome for a user-initiated check
    // (e.g. "Перевірити оновлення…" from the menu) is delivered through
    // this same `didAbortWithError` delegate method, disguised as an
    // NSError — `SUSparkleErrorDomain` code 1001 (`SUNoUpdateError`),
    // localized description "You're up to date!". That's Sparkle's normal
    // UI-driver plumbing (it needs an "abort" signal to dismiss the
    // checking-for-updates progress state either way), not a technical
    // failure — reporting it here was spamming the Telegram error channel
    // on every manual check that simply found nothing new. Matches this
    // project's existing "❌ real failures only, not normal business/data
    // outcomes" ErrorReporter convention (see e.g. KommoService's
    // "phone not found" case).
    private static let noUpdateFoundDomain = "SUSparkleErrorDomain"
    private static let noUpdateFoundCode = 1001

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        guard nsError.domain != Self.noUpdateFoundDomain || nsError.code != Self.noUpdateFoundCode else { return }
        Task { await ErrorReporter.shared.report(category: "AUTO_UPDATE", message: "Sparkle: перевірка/завантаження оновлення перервано помилкою.", error: error) }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let coordinator = CallRecordingCoordinator()
    private let monitor = CallMonitor()
    private lazy var pendingUploadRetryService = PendingUploadRetryService(coordinator: coordinator)
    // Phase 8.1: menu bar icon (Windows-parity: TrayViewModel's TaskbarIcon).
    // Held here, not as a local var in applicationDidFinishLaunching — an
    // NSStatusItem is removed from the menu bar as soon as its owning
    // object is deallocated, so it needs a strong reference for the whole
    // app lifetime, same reasoning as `coordinator`/`monitor` above.
    private var statusItemController: StatusItemController?
    // Phase 13.1/13.2: menu-bar/tray-adjacent floating widgets. Same
    // "held here, not a local var" reasoning as statusItemController above
    // — CheatSheetWindowController's NSPanel would be torn down the moment
    // its owning object deallocates if it weren't kept alive for the app's
    // whole lifetime, and worldClockController needs to outlive the single
    // `toggle()` call StatusItemController's menu item makes into it.
    private let cheatSheetController = CheatSheetWindowController()
    private let worldClockController = WorldClockWindowController()
    // Phase 9: owns the update lifecycle (background checks per Info
    // .plist's SUScheduledCheckInterval, the "Перевірити оновлення…" menu
    // item's target, and the whole download/verify/relaunch flow when an
    // update is found). `startingUpdater: true` matches Sparkle's own
    // SwiftUI-app guidance — no separate `.startUpdater()` call needed.
    // Held strongly for the app's lifetime for the same reason
    // `statusItemController` is: nothing else keeps it alive.
    private let updaterErrorReporter = UpdaterErrorReporter()
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: updaterErrorReporter,
        userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Phase 14: catch what we can of "this process is about to die"
        // before anything else runs — installed first so it's live for the
        // whole rest of startup, not just the code below it. Covers only
        // Objective-C NSExceptions (AppKit-adjacent crashes); Swift's own
        // fatal traps (force-unwrap, array-out-of-bounds, …) have no
        // interception point in pure Swift — see ErrorReporter's doc
        // comment for why that gap is accepted rather than chased with a
        // hand-rolled signal handler. `persistCrashSynchronously` writes
        // straight to disk (no actor hop, no network attempt) so the write
        // survives even though the process is already unwinding.
        NSSetUncaughtExceptionHandler { exception in
            ErrorReporter.persistCrashSynchronously(
                category: "CRASH_FATAL",
                message: exception.name.rawValue,
                detail: "\(exception.reason ?? "")\n\(exception.callStackSymbols.joined(separator: "\n"))")
        }
        Task { await ErrorReporter.shared.start() }

        // Phase 11.2: publish the running app's coordinator instance for
        // HomeView's manual start/stop button — see
        // CallRecordingCoordinator.appInstance's doc comment.
        CallRecordingCoordinator.appInstance = coordinator

        // `.regular` — matches Info.plist's LSUIElement=false: a Dock icon
        // (and Cmd+Tab entry) alongside the existing menu-bar item, not
        // instead of it (StatusItemController's NSStatusItem is untouched
        // by this). Phase 8.3 originally made this `.accessory` for
        // Windows-tray parity (no Dock icon at all); a later ask restored
        // the Dock icon while keeping the menu-bar affordance too, so the
        // app now has both simultaneously — a deliberate mac-only
        // enhancement over Windows, which only ever has the one tray icon.
        // Explicit here rather than left to Info.plist alone: SwiftPM
        // executables launched via Xcode's debugger don't get the automatic
        // frontmost-activation Finder-launched apps get for free, so the
        // explicit `.activate` call right below still matters regardless of
        // policy.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        statusItemController = StatusItemController(updaterController: updaterController, worldClockController: worldClockController)

        // Windows parity: App.xaml.cs kicks off an update check on every
        // launch (`mainVm.StartupUpdateCheckAsync()`), not just once/day.
        // `SUScheduledCheckInterval` above still governs Sparkle's own
        // background timer for long-running sessions, but without this
        // explicit call a same-day relaunch would silently skip checking
        // at all if Sparkle already checked earlier that day.
        // `checkForUpdatesInBackground()` respects `SUEnableAutomaticChecks`
        // (so it stays a no-op if the user has that setting off) and stays
        // silent unless an update is actually found — unlike
        // `checkForUpdates(_:)`, which always surfaces a "checking..." UI.
        updaterController.updater.checkForUpdatesInBackground()

        // Phase 13.3 — Windows parity: on Windows the main window's close
        // button *is* a full quit (no separate "minimize to tray"
        // affordance), and this app's default AppKit behavior for a
        // `.regular` app's last window closing (just close/hide it — the
        // process, menu-bar NSStatusItem, and now Dock icon all keep
        // running, only reachable again via StatusItemController's
        // "Відкрити ReplixerMac" item or the Dock icon) isn't what a red
        // traffic-light ✕ means to a user. Deliberately kept even after the
        // Dock icon was added (see `.setActivationPolicy(.regular)` above):
        // apps silently continuing to run after their visible window
        // closes are a common source of "why is this still using my mic"
        // confusion regardless of whether a Dock icon is present to hint at
        // it. So: become the delegate of the one-and-only
        // WindowGroup-created window (same `NSApp.windows.first` "there's
        // only ever one" assumption `StatusItemController.openMainWindow()`
        // already relies on) and route its close button through the exact
        // same full-termination path `StatusItemController.quit()` uses —
        // see `windowShouldClose(_:)` below.
        NSApp.windows.first?.delegate = self

        // Same startup sequence as ReplixerMacCallPoC/main.swift: sweep any
        // `.inprogress` file / dangling `.recording` history entry left by a
        // crash or force-quit on a previous run before doing anything else.
        FileNaming.cleanupStalePartialFiles()
        let reconciledCount = RecordingHistory.shared.reconcileDanglingRecordings()
        if reconciledCount > 0 {
            print("[ReplixerMacApp] ⚠️ Знайдено \(reconciledCount) запис(ів) історії, залишених у статусі \"recording\" після аварійного завершення — позначено як \"error\".")
            // Phase 14: this reconciliation finding anything at all is the
            // clearest signal available on Mac that the *previous* run
            // crashed mid-recording (see ErrorReporter's doc comment) —
            // there's no exception object to attach, just this fact itself.
            // Synchronous persist, not `report()`: ErrorReporter.shared
            // .start() above hasn't necessarily finished its actor hop yet,
            // and this path costs nothing extra to make crash-safe too.
            ErrorReporter.persistCrashSynchronously(
                category: "CRASH_STARTUP",
                message: "Попередній запуск завершився аварійно під час запису — \(reconciledCount) запис(ів) позначено як \"error\" при реконсиляції історії.")
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
                // Windows parity: OnCallEnded's
                // `if (!_isRecording) { DismissDialog(); return; }`. Not
                // recording yet most likely means the "start recording?"
                // dialog for this same call is still open and unanswered —
                // the call itself just disappeared out from under it (poll
                // saw mic+speaker both drop before the user ever tapped a
                // button). `submit(false)` resumes that dialog's suspended
                // `requestConfirmation` continuation exactly as if the user
                // had tapped "Пропустити" themselves, so `onCallStarted`'s
                // `guard confirmed else { return }` above unwinds cleanly
                // instead of the sheet sitting there asking to record a call
                // that no longer exists. Guarded on `.kind == .start`
                // specifically — CallMonitor only ever tracks one call at a
                // time, so there's nothing else this stale pending request
                // could be.
                guard await coordinator.isRecordingNow else {
                    if CallConfirmRequestStore.shared.pending?.kind == .start {
                        CallConfirmRequestStore.shared.submit(false)
                    }
                    return
                }
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
        // Phase 11.5: missed-call reports' Kommo delivery queue — same
        // "start once at launch, stop on quit" lifecycle as
        // pendingUploadRetryService above.
        MissedCallDeliveryService.shared.start()
        // Screenshot-upload retry queue — same "start once at launch, stop
        // on quit" lifecycle as the two services above.
        ScreenshotUploadRetryService.shared.start()

        // Windows parity: `App.xaml.cs`'s `ShowMissedCallReminder()` call,
        // gated the same way Windows gates its whole `ShowMainWindow()` —
        // only fires here if setup was already complete *before* this
        // launch. A fresh install (setup not yet done) instead gets it from
        // `SetupWizardView`'s `onFinish` callback in `ContentView`, once
        // the wizard itself sets `isSetupComplete = true`.
        if AppSettings.shared.isSetupComplete {
            MissedCallReminderWindowController.shared.show()
        }
    }

    /// Phase 13.3 — makes the main window's red ✕ a full quit instead of
    /// AppKit's default accessory-app "just close/hide the window" behavior
    /// (see the doc comment on the `NSApp.windows.first?.delegate = self`
    /// line above for why). Returning `false` here means the ✕ click itself
    /// never actually closes the window directly — instead `NSApp.terminate`
    /// drives the *entire* shutdown, including this same window's closing,
    /// through `applicationShouldTerminate(_:)` below, exactly like
    /// Cmd+Q/Dock-quit/`StatusItemController.quit()` already do. Unreachable
    /// while a sheet (`CallReportView`/`CallConfirmView`/
    /// `MissedCallReportView`) is attached — AppKit disables a window's
    /// close button for the whole time it has an attached sheet, so there's
    /// no risk of this firing mid-dialog.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    /// AppKit's async-shutdown hook: returning `.terminateLater` and calling
    /// `NSApp.reply(toApplicationShouldTerminate:)` once cleanup finishes
    /// lets Cmd+Q/Dock-quit wait for an in-flight recording to be finalized
    /// (renamed from `.inprogress`) and pending settings/history writes to
    /// flush — same intent as main.swift's SIGINT/SIGTERM handlers, adapted
    /// to how a real (non-CLI) macOS app actually gets asked to quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        pendingUploadRetryService.stop()
        MissedCallDeliveryService.shared.stop()
        ScreenshotUploadRetryService.shared.stop()
        Task { [coordinator] in
            await coordinator.shutdown()
            await ErrorReporter.shared.stop()
            AppSettings.shared.flush()
            RecordingHistory.shared.flush()
            MissedCallHistory.shared.flush()
            MissedCallDeliveryService.shared.flush()
            ScreenshotUploadRetryService.shared.flush()
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
