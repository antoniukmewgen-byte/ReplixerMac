import CoreAudio
import Foundation

/// Bridges CallMonitor's start/end events to AudioMixerEncoder's capture
/// pipeline: resolves the matched messenger's process object fresh at call
/// start (its AudioObjectID isn't guaranteed stable across separate calls),
/// builds a Windows-parity output path via FileNaming, and starts/stops
/// recording.
///
/// An actor, not a class with manual flags — Swift serializes calls to an
/// actor's methods automatically, so a rapid call-start/call-end flicker
/// from CallMonitor can't race into a double-start or double-stop (the
/// exact hazard the plan calls out for Phase 1.6; building on an actor now
/// avoids having to retrofit one later).
public actor CallRecordingCoordinator {
    // Explicit public init required: an implicit default init on an actor
    // is always internal-access, even when the actor itself is public —
    // main.swift (a different target) needs to be able to construct one.
    public init() {}

    /// Phase 11.2: `HomeView`'s manual start/stop button (SwiftUI,
    /// ReplixerMacApp) needs a reference to the *one* coordinator instance
    /// the running app actually owns. Deliberately not a `.shared`
    /// singleton the way `RecordingHistory`/`AppSettings`/etc. are —
    /// `CallRecordingCoordinator` is still meant to be a plain instance
    /// `ReplixerMacCallPoC/main.swift` can construct its own separate copy
    /// of as a UI-less runner (see `ReplixerMacApp.swift`'s `AppDelegate`
    /// doc comment on why the two never run at once against the same user).
    /// This is just a settable slot `AppDelegate` populates once at launch,
    /// left `nil` for the PoC target (which never reads it) and for any
    /// unit-test context that constructs a coordinator without an app around
    /// it.
    public static var appInstance: CallRecordingCoordinator?

    private var isRecording = false
    // Phase 2.2: tracks the RecordingHistory entry for the call currently
    // being recorded, so callEnded/shutdown can update its status (saved
    // vs error) without needing to search the history by e.g. start time.
    private var currentEntryID: UUID?
    // Phase 10.0: mirrors of the platform/start-time already captured for
    // this call — needed once callEnded's finishRecording() has to build a
    // CallReportRequestStore request and a caption (formatCaption's
    // `appName`/`duration` params), neither of which RecordingHistory
    // exposes back out mid-flight the way these plain actor-local fields do.
    private var currentPlatform: String?
    private var currentCallStartedAt: Date?

    // Phase 4.2: one TDLib session for the whole process lifetime, created
    // lazily on the first finished recording rather than at app startup —
    // if Telegram isn't configured yet (no apiId/apiHash/chatId), or the
    // user never runs a call, this coordinator never touches TDLib at all.
    // Relies on a session already having been established once via
    // `--telegram-login-smoke-test` (or a prior real run) — TDLib resumes
    // it silently from disk; if none exists yet, `login()` would block on
    // stdin for phone/code in the middle of otherwise unattended
    // operation, which is a known rough edge until Phase 7's UI replaces
    // this stdin-prompt flow.
    private var telegramAuthClient: TelegramAuthClient?
    // Tracks only the most recently kicked-off upload — good enough to let
    // shutdown() wait for "the" in-flight upload before closing the TDLib
    // client out from under it. Known gap: if a second call starts and
    // ends while an earlier upload is still in flight, this reference gets
    // overwritten and shutdown() would only wait for the newer one, not
    // both — acceptable for now (same "known gap, revisit later" standard
    // as the dangling-recording gap noted in RecordingHistory.addStarted).
    // Phase 5.3: now covers both the Drive and Telegram legs (they run
    // sequentially inside the same Task — see uploadRecording), not just
    // Telegram alone.
    private var pendingUploadTask: Task<Void, Never>?

    // Phase 6 fix: `retryPendingUploads()` suspends mid-flight on real
    // network calls (inside `UploadOrchestrator.run`) — and because this
    // whole type is an *actor*, Swift's reentrancy rules let a *different*
    // queued call (like `shutdown()`) start running during that suspension,
    // interleaved with the retry still in progress. Without tracking this,
    // `shutdown()` could reach `telegramAuthClient?.shutdown()` and close
    // the TDLib client while a background retry's TDLib request is still in
    // flight — the exact SIGSEGV risk `pendingUploadTask` above already
    // guards against for the "just-finished recording" upload path, just
    // for the *background retry* path, which an earlier version of this
    // comment incorrectly assumed didn't need the same protection.
    private var isRetryingUploads = false
    private var retryFinishedContinuations: [CheckedContinuation<Void, Never>] = []

    public func callStarted(messenger: SupportedMessenger, processName: String) {
        guard !isRecording else {
            print("[CallRecordingCoordinator] ⚠️ дзвінок вже записується, ігнорую повторний onCallStarted.")
            return
        }

        guard let processObjectID = ProcessTapSmokeTest.findProcessObjectID(for: messenger) else {
            print("[CallRecordingCoordinator] ❌ не знайшов \(messenger.rawValue) у CoreAudio-процесах на старті дзвінка.")
            return
        }

        _ = beginRecording(platform: messenger.rawValue, processObjectID: processObjectID)
    }

    public func callEnded(messenger: SupportedMessenger, processName: String) async {
        guard isRecording else {
            print("[CallRecordingCoordinator] ⚠️ onCallEnded без активного запису — ігнорую.")
            return
        }

        await finishRecording(requestReport: true)
        print("[CallRecordingCoordinator] ⏹️ запис зупинено.")
    }

    /// Phase 11.2, revised — Windows parity: `HomeViewModel
    /// .ManualStartRecording`. Windows never checks for a running messenger
    /// before a manual start (only its own `_isRecording`/`_isStopping`
    /// idempotency guards) and always tags the recording with the literal
    /// platform label `"Ручний запис"`, since `WasapiLoopbackCapture`
    /// captures whatever's making sound system-wide with no need to resolve
    /// "which app is calling". An earlier version of this method probed
    /// `SupportedMessenger.allCases` and *failed* the manual start outright
    /// if none of the four supported messengers happened to be running —
    /// that's exactly the messenger dependency Windows doesn't have, so it's
    /// gone now. `beginRecording(platform:processObjectID:)` is called with
    /// `processObjectID: nil`, which `AudioMixerEncoder.start` treats as
    /// "system-wide tap" (see its doc comment) — the mac-side equivalent of
    /// `WasapiLoopbackCapture`.
    public enum ManualStartOutcome: Equatable, Sendable {
        case started(platform: String)
        case alreadyRecording
        case failed
    }

    /// Windows parity: `PlatformHelper` treats this exact string as a
    /// first-class platform value (`ToDisplayName`/`ToFileName` both
    /// special-case it) — mirrored here as a plain string since mac's
    /// `FileNaming.recordingURL(platform:)` and `RecordingHistory` both
    /// already accept an arbitrary platform label, same as Windows'
    /// `RecordingEntry.Platform`.
    private static let manualPlatformLabel = "Ручний запис"

    public func manualStart() -> ManualStartOutcome {
        guard !isRecording else { return .alreadyRecording }

        guard beginRecording(platform: Self.manualPlatformLabel, processObjectID: nil) else {
            return .failed
        }
        return .started(platform: Self.manualPlatformLabel)
    }

    /// Phase 11.2 — Windows parity: `HomeViewModel.ManualStopRecording`.
    /// Just `finishRecording(requestReport: true)`, same as `callEnded` —
    /// `finishRecording` never actually reads a messenger/processName (it
    /// works off the already-stored `currentPlatform`), so there's no
    /// "synthesize a messenger" step needed for a manual stop the way
    /// `manualStart` needs one to begin.
    public func manualStop() async {
        guard isRecording else {
            print("[CallRecordingCoordinator] ⚠️ ручний стоп без активного запису — ігнорую.")
            return
        }

        await finishRecording(requestReport: true)
        print("[CallRecordingCoordinator] ⏹️ запис зупинено вручну.")
    }

    /// Phase 11.1: lets `ReplixerMacApp`'s `CallMonitor` wiring skip showing
    /// a "call ended — stop recording?" confirm dialog when nothing is
    /// actually being recorded — e.g. the matching "start recording?" dialog
    /// for this same detected call was answered "Пропустити". Windows
    /// parity: `OnCallEnded`'s `if (!_isRecording) { DismissDialog(); return; }`
    /// guard, just expressed as something the caller checks first rather
    /// than a no-op inside the callee (mac's confirm dialog has to exist
    /// *before* deciding whether to call `callEnded` at all, unlike Windows
    /// where the dialog and the record state live in the same object).
    public var isRecordingNow: Bool { isRecording }

    /// Shared by `callStarted`/`manualStart` — everything after "we know
    /// what to tap" (create the output dir, start the encoder, flip
    /// bookkeeping, mirror into `RecordingStatusStore`) is identical between
    /// an auto-detected and a manually-triggered start. `processObjectID` is
    /// `nil` only for `manualStart()`'s system-wide tap — `callStarted`
    /// always has a real messenger process object in hand by this point.
    private func beginRecording(platform: String, processObjectID: AudioObjectID?) -> Bool {
        do {
            try FileNaming.ensureRecordingsDirectoryExists()
        } catch {
            print("[CallRecordingCoordinator] ❌ не вдалося створити теку записів: \(error)")
            return false
        }

        let outputURL = FileNaming.recordingURL(platform: platform)
        guard AudioMixerEncoder.start(processObjectID: processObjectID, outputURL: outputURL) else {
            print("[CallRecordingCoordinator] ❌ не вдалося почати запис.")
            return false
        }

        isRecording = true
        currentEntryID = RecordingHistory.shared.addStarted(platform: platform)
        let startedAt = Date()
        currentPlatform = platform
        currentCallStartedAt = startedAt
        // Phase 7.5: mirror the state change into RecordingStatusStore so
        // HomeView (ReplixerMacApp, main thread) can show a live
        // "recording in progress" indicator without polling this actor.
        RecordingStatusStore.shared.update(.init(isRecording: true, platform: platform, startedAt: startedAt))
        print("[CallRecordingCoordinator] 🔴 запис почався -> \(outputURL.path)")
        return true
    }

    /// Called from main.swift's SIGINT/SIGTERM handlers so a Ctrl+C or
    /// `kill <pid>` during an active call still finalizes the recording
    /// (stop() renames the .inprogress file to its real name) instead of
    /// leaving a truncated file behind. Can't help against `kill -9`
    /// (SIGKILL isn't catchable) — FileNaming.cleanupStalePartialFiles()
    /// covers that case on the next startup instead.
    ///
    /// `async` (Phase 4.2 addition) so it can wait for any still-in-flight
    /// Telegram upload before tearing down the TDLib client — closing the
    /// client while a request is still using it is a known SIGSEGV risk
    /// (see TelegramAuthClient.shutdown()'s comments). Phase 6: also waits
    /// for an in-flight `retryPendingUploads()` for the same reason — see
    /// the `isRetryingUploads` doc comment above.
    public func shutdown() async {
        if isRecording {
            print("[CallRecordingCoordinator] 🛑 завершення роботи під час активного запису — коректно зупиняю...")
            // requestReport: false — quitting must not hang indefinitely
            // waiting on a report dialog the user may never fill in (no
            // Windows equivalent of this concern: its shutdown path
            // (App.OnExit) never awaits StopRecordingAsync's report step
            // either). The recording itself still finalizes correctly;
            // only the caption falls back to the generic one.
            await finishRecording(requestReport: false)
        }
        await pendingUploadTask?.value
        if isRetryingUploads {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                retryFinishedContinuations.append(continuation)
            }
        }
        telegramAuthClient?.shutdown()
    }

    /// Shared by callEnded/shutdown: stops the encoder, records the outcome
    /// (saved vs error) in RecordingHistory, optionally requests+awaits a
    /// call-report form (Phase 10.0 — Windows parity source:
    /// `HomeViewModel.StopRecordingAsync`'s `reportTask` await), and resets
    /// state either way — a failed stop() shouldn't leave `isRecording`
    /// stuck true.
    ///
    /// Phase 11.3 — Windows parity (`StopRecordingAsync`'s `_isRecording =
    /// false` right at the top, before either awaited task starts):
    /// `isRecording`/`currentEntryID`/`currentPlatform`/`currentCallStartedAt`
    /// are captured into locals and reset *before* the report-form await
    /// below, not after it — so a brand-new call arriving while the old
    /// report is still open isn't wrongly rejected by `callStarted`'s `guard
    /// !isRecording`. This is safe specifically because `AudioMixerEncoder
    /// .stop()` already ran synchronously above, before any `await` in this
    /// method — the encoder itself is free the instant this method's first
    /// line returns, so there's no hardware conflict for a new call's
    /// `AudioMixerEncoder.start()` to hit, only the (now-lifted) actor-level
    /// flag. Because this actor allows reentrancy across `await` points, a
    /// concurrent `beginRecording` genuinely can run while this method is
    /// suspended at the report await — reading `self.currentEntryID`/etc.
    /// again after that point would then risk picking up the *new* call's
    /// values instead of this (finishing) call's own, which is exactly what
    /// capturing locals first prevents.
    ///
    /// If a new call *does* arrive before the user submits the form,
    /// `ReplixerMacApp`'s `AppDelegate` calls `CallReportRequestStore.shared
    /// .interrupt()` before showing that call's confirm dialog (Windows
    /// parity: `ShowDialog` -> `DismissCallReport(interrupted: true)`) —
    /// `requestReport` below then returns `.interrupted(draft:)` instead of
    /// `.submitted(_:)`, and this method marks the entry `.draft` and skips
    /// upload entirely, same as `StopRecordingAsync`'s `wasInterrupted`
    /// branch.
    ///
    /// - Parameter requestReport: `false` from `shutdown()` — quitting
    ///   must not hang waiting on a report dialog nobody may ever answer.
    private func finishRecording(requestReport: Bool) async {
        let finalURL = AudioMixerEncoder.stop()
        RecordingStatusStore.shared.update(.idle)

        guard let entryID = currentEntryID else {
            isRecording = false
            currentPlatform = nil
            currentCallStartedAt = nil
            return
        }
        let platform = currentPlatform ?? ""
        // Frozen here (before the reset below) — Phase 10.1b's Kommo
        // call-metadata leg (first-contact date/processing speed) needs the
        // actual call-start `Date`, not just the already-computed
        // `duration` interval.
        let callStartedAt = currentCallStartedAt
        self.currentEntryID = nil
        currentPlatform = nil
        currentCallStartedAt = nil
        isRecording = false

        guard let finalURL else {
            RecordingHistory.shared.markFailed(id: entryID)
            return
        }

        RecordingHistory.shared.markFinished(id: entryID, filePath: finalURL.path)

        let duration = callStartedAt.map { Date().timeIntervalSince($0) } ?? 0

        // Windows parity (HomeViewModel.StopRecordingAsync): only bother
        // asking for a report if the answer would actually go somewhere —
        // Telegram (gated by role via PositionPolicy.isTelegramVisible) or,
        // since Phase 10.1a, Kommo (gated by nothing role-specific: every
        // position's canSubmit already requires crmUrl/note, so Kommo
        // applies uniformly, including Діагност — the one role
        // isTelegramVisible excludes). "Configured" (AppSecrets.telegramApiId
        // baked into this build, and telegramChatId set, or kommoApiToken
        // present) stands in for Windows' `_orchestrator.IsTelegramReady`/
        // Kommo-enabled checks — mac has no cheap synchronous "already
        // logged in" check without attempting a real login. Deliberately
        // still "configured" (not "configured AND isKommoEnabled") here —
        // this only decides whether to prompt for a report form at all, not
        // whether to actually deliver it; UploadOrchestrator.attemptKommo is
        // what gates the real Kommo write on isKommoEnabled.
        // apiId/apiHash themselves no longer live in AppSettings at all —
        // like googleServiceAccountJson, they're a build-time AppSecrets
        // constant now (see AppSecrets.example.swift), so there's nothing
        // per-user left to check for them beyond "did this build get one".
        let telegramConfigured = AppSecrets.telegramApiId != 0
            && !AppSecrets.telegramApiHash.isEmpty
            && AppSettings.shared.telegramChatId != nil
        let position = AppSettings.shared.position
        let wantsTelegram = telegramConfigured && PositionPolicy.isTelegramVisible(position)
        let kommoConfigured = AppSettings.shared.kommoSubdomain != nil && AppSettings.shared.kommoApiToken != nil
        let needsForm = requestReport && (wantsTelegram || kommoConfigured)

        let reportOutcome: CallReportRequestStore.Outcome? = needsForm
            ? await CallReportRequestStore.shared.requestReport(platform: platform, duration: duration)
            : nil

        // Phase 11.3 — Windows parity: StopRecordingAsync's `wasInterrupted`
        // branch. No upload at all; just persist whatever was captured as a
        // resumable draft and stop here.
        if case .interrupted(let draft) = reportOutcome {
            RecordingHistory.shared.markDraft(id: entryID, reportData: draft)
            print("[CallRecordingCoordinator] 📝 форма звіту перервана новим дзвінком — запис збережено як чернетку.")
            return
        }

        let reportData: CallReportData?
        if case .submitted(let data) = reportOutcome {
            reportData = data
        } else {
            reportData = nil
        }

        let fileName = finalURL.lastPathComponent
        let caption = reportData?.formatCaption(appName: platform, duration: duration)
            ?? "Запис дзвінку: \(fileName)"
        // Phase 11.4 fix: persist the submitted reportData onto the entry
        // too, not just its caption text — otherwise a later `editReport`
        // (which prefills the form from `entry.reportData`) would find
        // nothing to prefill with and open an empty form. No report shown
        // at all (`reportData == nil`) still falls back to the plain
        // caption-only write, same as before.
        if let reportData {
            RecordingHistory.shared.updateReportData(id: entryID, reportData: reportData, caption: caption)
        } else {
            RecordingHistory.shared.updateCaption(id: entryID, caption: caption)
        }

        let skipTelegram = PositionPolicy.shouldSkipTelegram(position, duration: duration)

        // Phase 4.2: fire the uploads off as a background Task rather than
        // awaiting them here — finishRecording() (and therefore
        // callEnded()) must return promptly so a rapid subsequent call
        // isn't wrongly rejected by the `isRecording` guard while a slow
        // upload is still running. shutdown() drains this task before
        // closing the TDLib client.
        //
        // crmUrl (Phase 10.1a) rides along the same Task now — since the
        // rework, UploadOrchestrator.run itself waits for Drive before
        // firing Telegram/Kommo, so there's no reason left for Kommo to be
        // a separate, earlier-firing Task the way it briefly was; see
        // UploadOrchestrator's doc comment.
        //
        // callType (Phase 10.1b) is the *resolved* type (custom-type
        // substitution already applied — see `CallReportData.resolvedCallType`),
        // matching what Windows' `HomeViewModel.ResolveCallType` feeds
        // `KommoService.ProcessLeadAsync`'s `callType` parameter.
        let crmUrl = reportData?.crmUrl
        let callType = reportData?.resolvedCallType
        pendingUploadTask = Task { [weak self] in
            await self?.uploadRecording(
                fileURL: finalURL, entryID: entryID, caption: caption, crmUrl: crmUrl,
                callStartedAt: callStartedAt, callType: callType, skipTelegram: skipTelegram)
        }
    }

    /// Phase 11.3 — Windows parity: `HomeViewModel.ResumeDraftAsync`.
    /// Re-opens the call-report form (prefilled from whatever was captured
    /// when the draft was interrupted) for a `.draft` entry, and on submit
    /// runs the same upload path `finishRecording` would have run
    /// originally. Deliberately doesn't touch `isRecording`/`currentEntryID`
    /// /etc. — resuming a draft isn't "a call", just a delayed report+upload
    /// for one that already fully finished recording, so it can safely run
    /// whether or not a brand-new call is being recorded at the same time.
    public enum ResumeDraftOutcome: Equatable, Sendable {
        case started
        case notFound
        case fileMissing
        /// Another report form (this call's own resumed one, or a
        /// brand-new call's) is already open — `CallReportRequestStore`
        /// only tracks one pending request at a time, so refusing here
        /// avoids silently orphaning whichever one is already in flight.
        case reportAlreadyOpen
        /// The resumed form itself got interrupted by yet another call
        /// before being submitted — the entry stays `.draft` (with its
        /// snapshot updated to whatever was captured this time), ready to
        /// be resumed again later.
        case interrupted
    }

    public func resumeDraft(entryID: UUID) async -> ResumeDraftOutcome {
        guard let entry = RecordingHistory.shared.entries.first(where: { $0.id == entryID }) else {
            return .notFound
        }
        guard entry.status == .draft, entry.hasRetryableFile, let filePath = entry.filePath else {
            return .fileMissing
        }
        guard CallReportRequestStore.shared.pending == nil else {
            return .reportAlreadyOpen
        }

        let fileURL = URL(fileURLWithPath: filePath)
        let outcome = await CallReportRequestStore.shared.requestReport(
            platform: entry.platform, duration: entry.callDuration, existing: entry.reportData)

        switch outcome {
        case .interrupted(let draft):
            RecordingHistory.shared.markDraft(id: entryID, reportData: draft)
            return .interrupted
        case .submitted(let reportData):
            let caption = reportData.formatCaption(appName: entry.platform, duration: entry.callDuration)
            // Phase 11.4 fix: same reasoning as finishRecording's — persist
            // reportData itself, not just the caption text, so a later
            // editReport has something to prefill the form with.
            RecordingHistory.shared.updateReportData(id: entryID, reportData: reportData, caption: caption)
            let skipTelegram = PositionPolicy.shouldSkipTelegram(AppSettings.shared.position, duration: entry.callDuration)
            let crmUrl = reportData.crmUrl
            let callType = reportData.resolvedCallType
            let callStartedAt = entry.startedAt
            pendingUploadTask = Task { [weak self] in
                await self?.resumeDraftUpload(
                    fileURL: fileURL, entryID: entryID, caption: caption, crmUrl: crmUrl,
                    callStartedAt: callStartedAt, callType: callType, skipTelegram: skipTelegram)
            }
            return .started
        }
    }

    /// Phase 11.3 — same Drive/Telegram/Kommo orchestration as
    /// `uploadRecording`, plus flipping the entry's status from `.draft` to
    /// `.saved`/`.error` once the attempt finishes (Windows parity:
    /// `ResumeDraftAsync` setting `entry.Status = RecordingStatus.Saved`/
    /// `.Error` after its own upload orchestration completes).
    /// `uploadRecording` itself never touches `.status` because the normal
    /// `finishRecording` path already set it to `.saved` up front, before
    /// the report form even opens — a resumed draft has no such earlier
    /// `.saved` write to rely on, so this does it explicitly at the end
    /// instead.
    private func resumeDraftUpload(
        fileURL: URL, entryID: UUID, caption: String, crmUrl: String?,
        callStartedAt: Date?, callType: String?, skipTelegram: Bool
    ) async {
        let client = await telegramClient()

        let result = await UploadOrchestrator.run(
            filePath: fileURL.path,
            caption: caption,
            crmUrl: crmUrl,
            callStartedAt: callStartedAt,
            callType: callType,
            existingDriveUrl: nil,
            existingTelegramMessageId: nil,
            // A .draft entry never reached the upload step before now (see
            // `finishRecording`'s `wasInterrupted` branch) — no Kommo note
            // could already exist for it, same reasoning as the nil
            // existingDriveUrl/existingTelegramMessageId above.
            existingKommoNoteId: nil,
            telegramClient: client,
            skipTelegram: skipTelegram
        )

        RecordingHistory.shared.updateUploadState(
            id: entryID,
            driveUrl: result.driveUrl,
            driveFailed: result.driveFailed,
            telegramMessageId: result.telegramMessageId,
            telegramFailed: result.telegramFailed,
            kommoNoteId: result.kommoNoteId
        )
        RecordingHistory.shared.markDraftResolved(id: entryID, succeeded: !result.driveFailed && !result.telegramFailed)
    }

    /// Phase 11.4 — Windows parity: `HomeViewModel.EditEntryReportAsync`.
    /// Re-opens the call-report form prefilled with `entry.reportData` for
    /// an already fully-sent entry, and on submit patches the already-sent
    /// Telegram message's caption and the already-created Kommo note's text
    /// *in place* — rather than sending new ones — via
    /// `TelegramUploadService.editCaption`/`KommoService.editNote`, run
    /// concurrently (`async let`, Windows parity: `Task.WhenAll` over
    /// `EditTelegramCaptionAsync`/`EditKommoNoteAsync`). Only persists the
    /// new `reportData`/caption onto the entry
    /// (`RecordingHistory.updateReportData`) once *both* edits report
    /// success — a partial success (e.g. Telegram edited but Kommo failed)
    /// leaves the stored report untouched, and surfaces a combined error
    /// naming exactly which leg(s) failed, same as Windows'
    /// `string.Join("\n", ...)` over both warnings.
    public enum EditReportOutcome: Equatable, Sendable {
        case succeeded
        case notFound
        /// Nothing to edit against — Windows gates the "Редагувати" button
        /// on `HasTelegramMessage`; mirrored here as a hard precondition
        /// rather than a UI-only gate, so a stale/racing call can't slip
        /// through.
        case noTelegramMessage
        case reportAlreadyOpen
        case interrupted
        case failed(String)
    }

    public func editReport(entryID: UUID) async -> EditReportOutcome {
        guard let entry = RecordingHistory.shared.entries.first(where: { $0.id == entryID }) else {
            return .notFound
        }
        guard let messageId = entry.telegramMessageId else {
            return .noTelegramMessage
        }
        guard CallReportRequestStore.shared.pending == nil else {
            return .reportAlreadyOpen
        }

        let outcome = await CallReportRequestStore.shared.requestReport(
            platform: entry.platform, duration: entry.callDuration, existing: entry.reportData)

        guard case .submitted(let reportData) = outcome else {
            return .interrupted
        }

        let caption = reportData.formatCaption(appName: entry.platform, duration: entry.callDuration)
        let callType = reportData.resolvedCallType

        async let telegramWarning: String? = editTelegramCaption(
            entryID: entryID, messageId: messageId, caption: caption, driveUrl: entry.driveUrl)
        async let kommoWarning: String? = editKommoNote(
            crmUrl: reportData.crmUrl, noteId: entry.kommoNoteId, caption: caption,
            driveUrl: entry.driveUrl, callType: callType)

        let warnings = [await telegramWarning, await kommoWarning].compactMap { $0 }

        guard warnings.isEmpty else {
            return .failed(warnings.joined(separator: "\n"))
        }

        RecordingHistory.shared.updateReportData(id: entryID, reportData: reportData, caption: caption)
        return .succeeded
    }

    /// Wraps `TelegramUploadService.editCaption`'s throwing shape into the
    /// `String?`-warning shape `editReport` aggregates both legs with —
    /// Windows parity: `EditTelegramCaptionAsync`'s own try/catch returning
    /// a human string instead of rethrowing. The `.messageDeleted` case
    /// additionally clears the entry's stored `telegramMessageId` (Windows:
    /// `entry.TelegramMessageId = null` in the same catch), since the
    /// message this id pointed at is now confirmed gone — leaving the stale
    /// id around would just make every future edit attempt fail the same
    /// way.
    private func editTelegramCaption(entryID: UUID, messageId: Int64, caption: String, driveUrl: String?) async -> String? {
        guard let client = await telegramClient() else {
            return "Telegram: не вдалося встановити з'єднання"
        }
        guard let chatId = AppSettings.shared.telegramChatId else {
            return "Telegram: не налаштовано чат"
        }
        do {
            try await TelegramUploadService.editCaption(
                messageId: messageId, chatId: chatId, caption: caption, driveUrl: driveUrl, authClient: client)
            return nil
        } catch TelegramUploadService.EditCaptionError.messageDeleted {
            RecordingHistory.shared.clearTelegramMessageId(id: entryID)
            return TelegramUploadService.messageDeletedWarning
        } catch {
            return "Telegram: \(error)"
        }
    }

    /// Windows parity: `EditKommoNoteAsync`. No-op (returns nil — nothing to
    /// report as failed) when Kommo was never part of this entry's original
    /// upload (`crmUrl`/`noteId` missing), same as `UploadOrchestrator
    /// .attemptKommo` treating a missing crmUrl as "skip, not fail".
    private func editKommoNote(crmUrl: String?, noteId: Int64?, caption: String, driveUrl: String?, callType: String?) async -> String? {
        guard let crmUrl, let noteId else { return nil }
        let text: String = {
            guard let driveUrl, !driveUrl.isEmpty else { return caption }
            return caption + "\n💾 Google Drive: \(driveUrl)"
        }()
        return await KommoService.editNote(leadUrl: crmUrl, noteId: noteId, noteText: text, callType: callType)
    }

    /// Phase 5.3/6/10.1a/10.1b: runs the configured Drive/Telegram/Kommo
    /// steps for a just-finished recording via `UploadOrchestrator` (Drive
    /// first, so its resulting link can be embedded in both the Telegram
    /// caption and the Kommo note — Windows-parity `BuildCaption`'s
    /// "💾 Google Drive: {url}" line — before Telegram-send and the Kommo
    /// note+call-metadata legs fire concurrently), then persists the
    /// Drive/Telegram outcome to `RecordingHistory` so any step that failed
    /// gets picked up later by `retryPendingUploads()` instead of being
    /// lost. Kommo has no such tracking (see
    /// `UploadOrchestrator.attemptKommo`'s doc comment).
    private func uploadRecording(
        fileURL: URL, entryID: UUID, caption: String, crmUrl: String?,
        callStartedAt: Date?, callType: String?, skipTelegram: Bool
    ) async {
        let client = await telegramClient()

        let result = await UploadOrchestrator.run(
            filePath: fileURL.path,
            caption: caption,
            crmUrl: crmUrl,
            callStartedAt: callStartedAt,
            callType: callType,
            existingDriveUrl: nil,
            existingTelegramMessageId: nil,
            existingKommoNoteId: nil,
            telegramClient: client,
            skipTelegram: skipTelegram
        )

        RecordingHistory.shared.updateUploadState(
            id: entryID,
            driveUrl: result.driveUrl,
            driveFailed: result.driveFailed,
            telegramMessageId: result.telegramMessageId,
            telegramFailed: result.telegramFailed,
            kommoNoteId: result.kommoNoteId
        )
    }

    /// Phase 6: re-attempts Drive/Telegram for any recording whose last
    /// attempt left something unfinished (network hiccup, Telegram login
    /// not ready at the time, etc.) and whose local file is still around to
    /// retry with. Called on a timer by `PendingUploadRetryService`. Safe to
    /// run concurrently with `callStarted`/`callEnded` — actor isolation
    /// still prevents those from racing on shared state — but `shutdown()`
    /// specifically needs the `isRetryingUploads`/`retryFinishedContinuations`
    /// bookkeeping below: an actor's reentrancy means `shutdown()` *can*
    /// start running while this method is suspended mid-`await`, so without
    /// tracking that explicitly, `shutdown()` could close the TDLib client
    /// out from under a retry that's still using it.
    func retryPendingUploads() async {
        let candidates = RecordingHistory.shared.beginRetryCandidates()
        guard !candidates.isEmpty else { return }

        isRetryingUploads = true
        defer {
            isRetryingUploads = false
            let continuations = retryFinishedContinuations
            retryFinishedContinuations = []
            for continuation in continuations {
                continuation.resume()
            }
        }

        for entry in candidates {
            guard let filePath = entry.filePath else {
                // Shouldn't happen — `needsBackgroundRetry` already checks
                // filePath/file-existence — but guard anyway rather than
                // force-unwrap, and release the in-progress flag either way.
                RecordingHistory.shared.endBackgroundRetry(id: entry.id)
                continue
            }

            let fileName = (filePath as NSString).lastPathComponent
            // Reuse the caption captured at call-end time (Phase 10.0's
            // call-report caption, if one was shown) rather than
            // reconstructing the generic fallback here — see
            // RecordingEntry.caption's doc comment. Only entries written
            // before that field existed fall back to the generic text.
            let caption = entry.caption ?? "Запис дзвінку: \(fileName)"
            let skipTelegram = PositionPolicy.shouldSkipTelegram(AppSettings.shared.position, duration: entry.callDuration)
            // Resolved even when Telegram already has a messageId: if
            // *Drive* is what this entry is retrying and it succeeds now,
            // UploadOrchestrator needs a client to patch the already-sent
            // Telegram message's caption with the new Drive link (see
            // UploadOrchestrator.run's driveJustSucceeded branch).
            let client = await telegramClient()

            let result = await UploadOrchestrator.run(
                filePath: filePath,
                caption: caption,
                // RecordingEntry has no crmUrl/callStartedAt/callType fields
                // (never persisted — see RecordingEntry's doc comment), so a
                // background retry can never attempt/re-attempt the Kommo
                // note or call-metadata legs, only Drive/Telegram.
                crmUrl: nil,
                callStartedAt: nil,
                callType: nil,
                existingDriveUrl: entry.driveUrl,
                existingTelegramMessageId: entry.telegramMessageId,
                // Preserves whatever note id an earlier attempt already
                // captured — crmUrl is always nil on a background retry (see
                // the doc comment on the `crmUrl:` argument a few lines up),
                // so attemptKommo never posts a *new* note here; it just
                // hands this back unchanged.
                existingKommoNoteId: entry.kommoNoteId,
                telegramClient: client,
                skipTelegram: skipTelegram
            )

            RecordingHistory.shared.updateUploadState(
                id: entry.id,
                driveUrl: result.driveUrl,
                driveFailed: result.driveFailed,
                telegramMessageId: result.telegramMessageId,
                telegramFailed: result.telegramFailed,
                kommoNoteId: result.kommoNoteId
            )

            if !result.driveFailed && !result.telegramFailed {
                print("[CallRecordingCoordinator] ✅ фоновий retry доробив запис \(fileName).")
            }

            RecordingHistory.shared.endBackgroundRetry(id: entry.id)
        }
    }

    /// Returns the process-lifetime Telegram auth client (TDLib session
    /// wrapper), logging in lazily on first use. Reuses `telegramAuthClient`
    /// across calls so a second recording doesn't re-authenticate from
    /// scratch. Returns nil (with a log line) when apiId/apiHash aren't
    /// configured yet, rather than throwing — callers treat "Telegram not
    /// set up" as a normal skip, not an error.
    ///
    /// Returns the auth-client wrapper itself, not just its `.client` —
    /// `TelegramUploadService.sendRecording`'s Phase 6 fix needs
    /// `TelegramAuthClient.finalMessageId(forTemporaryId:)` (correlates
    /// `sendMessage`'s temporary id to the server-confirmed final id via
    /// `updateMessageSendSucceeded`) alongside the raw TDLib client, and
    /// that correlation only lives on the auth-client wrapper.
    private func telegramClient() async -> TelegramAuthClient? {
        if let telegramAuthClient {
            return telegramAuthClient
        }
        let newClient = TelegramAuthClient()
        do {
            try await newClient.login()
        } catch TelegramAuthError.missingCredentials {
            print("[CallRecordingCoordinator] ℹ️ AppSecrets.telegramApiId/telegramApiHash не налаштовані в цій збірці — пропускаю автоматичну відправку в Telegram.")
            return nil
        } catch {
            print("[CallRecordingCoordinator] ❌ авторизація Telegram провалилась: \(error)")
            return nil
        }
        telegramAuthClient = newClient
        return newClient
    }
}
