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
        print("[CallRecordingCoordinator] 🔴 запис почався -> \(outputURL.path)")
    }

    public func callEnded(messenger: SupportedMessenger, processName: String) {
        guard isRecording else {
            print("[CallRecordingCoordinator] ⚠️ onCallEnded без активного запису — ігнорую.")
            return
        }

        finishRecording()
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
            finishRecording()
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
    /// (saved vs error) in RecordingHistory, and resets state either way —
    /// a failed stop() shouldn't leave `isRecording` stuck true.
    private func finishRecording() {
        let finalURL = AudioMixerEncoder.stop()
        if let currentEntryID {
            if let finalURL {
                RecordingHistory.shared.markFinished(id: currentEntryID, filePath: finalURL.path)
                // Phase 4.2: fire the uploads off as a background Task
                // rather than awaiting them here — finishRecording() (and
                // therefore callEnded()) must return promptly so a rapid
                // subsequent call isn't wrongly rejected by the `isRecording`
                // guard while a slow upload is still running. shutdown()
                // drains this task before closing the TDLib client.
                // Captured explicitly (not read back from `self` inside the
                // Task) because `currentEntryID` gets reset to nil right
                // below, before the Task body ever runs.
                let entryID = currentEntryID
                pendingUploadTask = Task { [weak self] in
                    await self?.uploadRecording(fileURL: finalURL, entryID: entryID)
                }
            } else {
                RecordingHistory.shared.markFailed(id: currentEntryID)
            }
        }
        currentEntryID = nil
        isRecording = false
    }

    /// Phase 5.3/6: runs both configured uploads for a just-finished
    /// recording via `UploadOrchestrator` (Drive first, so its resulting
    /// link can be embedded in the Telegram caption — Windows-parity
    /// `BuildCaption`'s "💾 Google Drive: {url}" line), then persists the
    /// outcome to `RecordingHistory` so any step that failed gets picked up
    /// later by `retryPendingUploads()` instead of being lost.
    private func uploadRecording(fileURL: URL, entryID: UUID) async {
        let fileName = fileURL.lastPathComponent
        let caption = "Запис дзвінку: \(fileName)"
        let client = await telegramClient()

        let result = await UploadOrchestrator.run(
            filePath: fileURL.path,
            caption: caption,
            existingDriveUrl: nil,
            existingTelegramMessageId: nil,
            telegramClient: client
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
            let caption = "Запис дзвінку: \(fileName)"
            // Resolved even when Telegram already has a messageId: if
            // *Drive* is what this entry is retrying and it succeeds now,
            // UploadOrchestrator needs a client to patch the already-sent
            // Telegram message's caption with the new Drive link (see
            // UploadOrchestrator.run's driveJustSucceeded branch).
            let client = await telegramClient()

            let result = await UploadOrchestrator.run(
                filePath: filePath,
                caption: caption,
                existingDriveUrl: entry.driveUrl,
                existingTelegramMessageId: entry.telegramMessageId,
                telegramClient: client
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
