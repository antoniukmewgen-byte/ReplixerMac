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

        do {
            try FileNaming.ensureRecordingsDirectoryExists()
        } catch {
            print("[CallRecordingCoordinator] ❌ не вдалося створити теку записів: \(error)")
            return
        }

        let platform = messenger.rawValue
        let outputURL = FileNaming.recordingURL(platform: platform)
        guard AudioMixerEncoder.start(processObjectID: processObjectID, outputURL: outputURL) else {
            print("[CallRecordingCoordinator] ❌ не вдалося почати запис.")
            return
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
    }

    public func callEnded(messenger: SupportedMessenger, processName: String) async {
        guard isRecording else {
            print("[CallRecordingCoordinator] ⚠️ onCallEnded без активного запису — ігнорую.")
            return
        }

        await finishRecording(requestReport: true)
        print("[CallRecordingCoordinator] ⏹️ запис зупинено.")
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
    /// `isRecording` deliberately stays true for the *entire* duration of
    /// this method, including the report-form await — mac has no
    /// Windows-style draft/interrupt handling for a second call arriving
    /// while a report is still open (see `RecordingsView`'s "no `.draft`
    /// status" doc comment), so keeping the guard up for that whole window
    /// means a genuinely overlapping call is simply dropped by
    /// `callStarted`'s existing guard rather than silently corrupting
    /// state. `RecordingStatusStore` is still reset to `.idle` immediately
    /// after the encoder stops, independent of how long the report form
    /// stays open — matching Windows' `StopRecordingAsync`, which flips
    /// `CallContent` back to idle right away and lets the report dialog
    /// float on top rather than block the "idle" UI state from showing.
    ///
    /// - Parameter requestReport: `false` from `shutdown()` — quitting
    ///   must not hang waiting on a report dialog nobody may ever answer.
    private func finishRecording(requestReport: Bool) async {
        let finalURL = AudioMixerEncoder.stop()
        RecordingStatusStore.shared.update(.idle)

        guard let currentEntryID else {
            isRecording = false
            currentPlatform = nil
            currentCallStartedAt = nil
            return
        }

        guard let finalURL else {
            RecordingHistory.shared.markFailed(id: currentEntryID)
            self.currentEntryID = nil
            currentPlatform = nil
            currentCallStartedAt = nil
            isRecording = false
            return
        }

        RecordingHistory.shared.markFinished(id: currentEntryID, filePath: finalURL.path)

        let platform = currentPlatform ?? ""
        let duration = currentCallStartedAt.map { Date().timeIntervalSince($0) } ?? 0

        // Windows parity (HomeViewModel.StopRecordingAsync): only bother
        // asking for a report if the answer would actually go somewhere —
        // Telegram (gated by role via PositionPolicy.isTelegramVisible) or,
        // since Phase 10.1a, Kommo (gated by nothing role-specific: every
        // position's canSubmit already requires crmUrl/note, so Kommo
        // applies uniformly, including Діагност — the one role
        // isTelegramVisible excludes). "Configured" (apiId/apiHash/chatId
        // all present, or kommoApiToken present) stands in for Windows'
        // `_orchestrator.IsTelegramReady`/Kommo-enabled checks — mac has no
        // cheap synchronous "already logged in" check without attempting a
        // real login, and no separate isKommoEnabled flag (see
        // AppSettings.kommoApiToken's doc comment).
        let telegramConfigured = AppSettings.shared.telegramApiId != nil
            && AppSettings.shared.telegramApiHash != nil
            && AppSettings.shared.telegramChatId != nil
        let position = AppSettings.shared.position
        let wantsTelegram = telegramConfigured && PositionPolicy.isTelegramVisible(position)
        let kommoConfigured = AppSettings.shared.kommoSubdomain != nil && AppSettings.shared.kommoApiToken != nil
        let needsForm = requestReport && (wantsTelegram || kommoConfigured)

        let reportData: CallReportData? = needsForm
            ? await CallReportRequestStore.shared.requestReport(platform: platform, duration: duration)
            : nil

        let fileName = finalURL.lastPathComponent
        let caption = reportData?.formatCaption(appName: platform, duration: duration)
            ?? "Запис дзвінку: \(fileName)"
        RecordingHistory.shared.updateCaption(id: currentEntryID, caption: caption)

        let skipTelegram = PositionPolicy.shouldSkipTelegram(position, duration: duration)

        // Phase 4.2: fire the uploads off as a background Task rather than
        // awaiting them here — finishRecording() (and therefore
        // callEnded()) must return promptly so a rapid subsequent call
        // isn't wrongly rejected by the `isRecording` guard while a slow
        // upload is still running. shutdown() drains this task before
        // closing the TDLib client. Captured explicitly (not read back
        // from `self` inside the Task) because `currentEntryID` gets reset
        // to nil right below, before the Task body ever runs.
        //
        // crmUrl (Phase 10.1a) rides along the same Task now — since the
        // rework, UploadOrchestrator.run itself waits for Drive before
        // firing Telegram/Kommo, so there's no reason left for Kommo to be
        // a separate, earlier-firing Task the way it briefly was; see
        // UploadOrchestrator's doc comment.
        let entryID = currentEntryID
        let crmUrl = reportData?.crmUrl
        pendingUploadTask = Task { [weak self] in
            await self?.uploadRecording(fileURL: finalURL, entryID: entryID, caption: caption, crmUrl: crmUrl, skipTelegram: skipTelegram)
        }

        self.currentEntryID = nil
        currentPlatform = nil
        currentCallStartedAt = nil
        isRecording = false
    }

    /// Phase 5.3/6/10.1a: runs the configured Drive/Telegram/Kommo steps
    /// for a just-finished recording via `UploadOrchestrator` (Drive first,
    /// so its resulting link can be embedded in both the Telegram caption
    /// and the Kommo note — Windows-parity `BuildCaption`'s
    /// "💾 Google Drive: {url}" line — before Telegram-send and the Kommo
    /// note fire concurrently), then persists the Drive/Telegram outcome to
    /// `RecordingHistory` so any step that failed gets picked up later by
    /// `retryPendingUploads()` instead of being lost. Kommo has no such
    /// tracking (see `UploadOrchestrator.attemptKommo`'s doc comment).
    private func uploadRecording(fileURL: URL, entryID: UUID, caption: String, crmUrl: String?, skipTelegram: Bool) async {
        let client = await telegramClient()

        let result = await UploadOrchestrator.run(
            filePath: fileURL.path,
            caption: caption,
            crmUrl: crmUrl,
            existingDriveUrl: nil,
            existingTelegramMessageId: nil,
            telegramClient: client,
            skipTelegram: skipTelegram
        )

        RecordingHistory.shared.updateUploadState(
            id: entryID,
            driveUrl: result.driveUrl,
            driveFailed: result.driveFailed,
            telegramMessageId: result.telegramMessageId,
            telegramFailed: result.telegramFailed
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
                // RecordingEntry has no crmUrl field (never persisted —
                // see its doc comment), so a background retry can never
                // attempt/re-attempt the Kommo note, only Drive/Telegram.
                crmUrl: nil,
                existingDriveUrl: entry.driveUrl,
                existingTelegramMessageId: entry.telegramMessageId,
                telegramClient: client,
                skipTelegram: skipTelegram
            )

            RecordingHistory.shared.updateUploadState(
                id: entry.id,
                driveUrl: result.driveUrl,
                driveFailed: result.driveFailed,
                telegramMessageId: result.telegramMessageId,
                telegramFailed: result.telegramFailed
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
            print("[CallRecordingCoordinator] ℹ️ telegramApiId/telegramApiHash не налаштовані — пропускаю автоматичну відправку в Telegram.")
            return nil
        } catch {
            print("[CallRecordingCoordinator] ❌ авторизація Telegram провалилась: \(error)")
            return nil
        }
        telegramAuthClient = newClient
        return newClient
    }
}
