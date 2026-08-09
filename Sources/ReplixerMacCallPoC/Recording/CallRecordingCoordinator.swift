import CoreAudio
import Foundation
import TDLibKit

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
actor CallRecordingCoordinator {
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

    func callStarted(messenger: SupportedMessenger, processName: String) {
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

    func callEnded(messenger: SupportedMessenger, processName: String) {
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
    /// (see TelegramAuthClient.shutdown()'s comments).
    func shutdown() async {
        if isRecording {
            print("[CallRecordingCoordinator] 🛑 завершення роботи під час активного запису — коректно зупиняю...")
            finishRecording()
        }
        await pendingUploadTask?.value
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
                pendingUploadTask = Task { [weak self] in
                    await self?.uploadRecording(fileURL: finalURL)
                }
            } else {
                RecordingHistory.shared.markFailed(id: currentEntryID)
            }
        }
        currentEntryID = nil
        isRecording = false
    }

    /// Phase 5.3: runs both configured uploads for a just-finished
    /// recording, Drive first so its resulting link can be embedded in the
    /// Telegram caption (Windows-parity `BuildCaption`'s
    /// "💾 Google Drive: {url}" line — `TelegramUploadService`'s `driveUrl`
    /// parameter existed since Phase 4.2 specifically for this, just had
    /// nothing to pass it until now). Sequential, not parallel, precisely
    /// because of that dependency; Drive failing/being unconfigured doesn't
    /// block the Telegram leg — `uploadToGoogleDrive` degrades to nil
    /// instead of throwing.
    private func uploadRecording(fileURL: URL) async {
        let driveUrl = await uploadToGoogleDrive(fileURL: fileURL)
        await uploadToTelegram(fileURL: fileURL, driveUrl: driveUrl)
    }

    /// Sends a just-finished recording to the configured Google Drive
    /// folder. Silently skips (with a log line, not an error) when Drive
    /// isn't configured at all — same opt-in-automation reasoning as
    /// `uploadToTelegram`'s telegramChatId guard below. Returns the
    /// uploaded file's webViewLink on success, nil on skip *or* failure —
    /// a Drive hiccup should never take down the Telegram upload that
    /// follows, so the error is logged here rather than rethrown.
    private func uploadToGoogleDrive(fileURL: URL) async -> String? {
        guard AppSettings.shared.googleServiceAccountPath != nil,
              AppSettings.shared.googleDriveFolderId != nil else {
            print("[CallRecordingCoordinator] ℹ️ googleServiceAccountPath/googleDriveFolderId не налаштовано — пропускаю автоматичне завантаження в Google Drive.")
            return nil
        }
        do {
            let link = try await GoogleDriveUploadService.upload(filePath: fileURL.path)
            print("[CallRecordingCoordinator] ✅ запис завантажено в Google Drive — \(link)")
            return link
        } catch {
            print("[CallRecordingCoordinator] ❌ не вдалося завантажити запис у Google Drive: \(error)")
            return nil
        }
    }

    /// Sends a just-finished recording to the configured Telegram chat/topic.
    /// Silently skips (with a log line, not an error) when Telegram isn't
    /// configured at all — this is opt-in automation, not a hard requirement
    /// for local recording to work. `driveUrl` (Phase 5.3) is nil whenever
    /// Drive upload was skipped or failed — `buildCaption` already treats a
    /// nil/empty driveUrl as "omit that caption line", so no extra branching
    /// is needed here.
    private func uploadToTelegram(fileURL: URL, driveUrl: String?) async {
        guard AppSettings.shared.telegramChatId != nil else {
            print("[CallRecordingCoordinator] ℹ️ telegramChatId не налаштовано — пропускаю автоматичну відправку в Telegram.")
            return
        }
        guard let client = await telegramClient() else { return }

        let fileName = fileURL.lastPathComponent
        do {
            let messageId = try await TelegramUploadService.sendRecording(
                filePath: fileURL.path,
                caption: "Запис дзвінку: \(fileName)",
                driveUrl: driveUrl,
                client: client
            )
            print("[CallRecordingCoordinator] ✅ запис надіслано в Telegram — messageId=\(messageId).")
        } catch {
            print("[CallRecordingCoordinator] ❌ не вдалося надіслати запис у Telegram: \(error)")
        }
    }

    /// Returns the process-lifetime TDLib client, logging in lazily on first
    /// use. Reuses `telegramAuthClient` across calls so a second recording
    /// doesn't re-authenticate from scratch. Returns nil (with a log line)
    /// when apiId/apiHash aren't configured yet, rather than throwing —
    /// callers treat "Telegram not set up" as a normal skip, not an error.
    private func telegramClient() async -> TDLibClient? {
        if let telegramAuthClient {
            return telegramAuthClient.client
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
        return newClient.client
    }
}
