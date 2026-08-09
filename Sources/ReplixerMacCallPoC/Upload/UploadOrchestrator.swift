import Foundation

/// Phase 6: attempts the Drive+Telegram upload steps for a recording,
/// skipping any step that's already succeeded — shared by
/// `CallRecordingCoordinator`'s "just finished recording" path and
/// `PendingUploadRetryService`'s "try the steps that failed last time"
/// path, so the two don't duplicate the same guard/attempt/log logic.
///
/// Windows parity source: `UploadOrchestrator.cs`, scoped down — no Kommo
/// leg yet (Phase 10, not built), and no `ReportData`/caption-form concept
/// on macOS yet (no Phase 7 UI), so `caption` is passed straight through
/// rather than built from a report form.
///
/// Simplification vs Windows: `UploadOrchestrator.cs`'s `RetryMissingStepsAsync`
/// takes separate `needDrive`/`needTelegram` flags (from
/// `RecordingEntry.DriveFailed`/`TelegramFailed`) to decide what to retry.
/// Here, "already have a value" (`existingDriveUrl`/`existingTelegramMessageId`
/// non-nil) already fully encodes "this step is done, skip it" — a step
/// that was simply never configured stays nil forever and its `*Failed`
/// flag never gets set to true, so `RecordingHistory.needsBackgroundRetry`
/// never selects it in the first place. No separate need-flags required.
enum UploadOrchestrator {
    struct Result {
        var driveUrl: String?
        var driveFailed: Bool
        var telegramMessageId: Int64?
        var telegramFailed: Bool
    }

    /// - Parameters:
    ///   - existingDriveUrl/existingTelegramMessageId: already-succeeded
    ///     values from a prior attempt. A non-nil value here means "skip
    ///     this step entirely, don't re-run it" — re-running would
    ///     re-upload a file already on Drive, or duplicate a Telegram
    ///     message.
    ///   - telegramClient: the Telegram auth-client wrapper, pre-resolved by
    ///     the caller — `CallRecordingCoordinator` owns the actual TDLib
    ///     session/login caching (it's the only actor touching TDLib), this
    ///     type stays a stateless enum. Passed as `TelegramAuthClient`
    ///     rather than the raw `TDLibClient` because the Phase 6
    ///     caption-patch fix needs `finalMessageId(forTemporaryId:)`
    ///     alongside the raw client — see `TelegramUploadService.sendRecording`.
    ///     `nil` means "don't attempt Telegram at all right now" (not logged
    ///     in / login failed) — see below for how that's distinguished from
    ///     "not configured".
    static func run(
        filePath: String,
        caption: String,
        existingDriveUrl: String?,
        existingTelegramMessageId: Int64?,
        telegramClient: TelegramAuthClient?
    ) async -> Result {
        var driveUrl = existingDriveUrl
        var driveFailed = false
        var driveJustSucceeded = false
        if driveUrl == nil {
            (driveUrl, driveFailed) = await attemptGoogleDrive(filePath: filePath)
            driveJustSucceeded = driveUrl != nil
        }

        var telegramMessageId = existingTelegramMessageId
        var telegramFailed = false
        if telegramMessageId == nil {
            (telegramMessageId, telegramFailed) = await attemptTelegram(
                filePath: filePath, caption: caption, driveUrl: driveUrl, client: telegramClient)
        } else if driveJustSucceeded, let driveUrl, let telegramClient, let sentMessageId = telegramMessageId {
            // Telegram was already sent by an earlier attempt — at a time
            // when Drive hadn't succeeded yet, so its caption has no Drive
            // link. Drive just succeeded *now* (this run), so patch the
            // existing message rather than leaving it permanently missing
            // the link — see TelegramUploadService.editCaption's doc
            // comment for why this can't just rely on a manual "edit"
            // action the way Windows does.
            await patchTelegramCaptionWithDriveLink(
                messageId: sentMessageId, caption: caption, driveUrl: driveUrl, authClient: telegramClient)
        }

        return Result(
            driveUrl: driveUrl,
            driveFailed: driveFailed,
            telegramMessageId: telegramMessageId,
            telegramFailed: telegramFailed
        )
    }

    /// Silently skips (not a failure) when Drive isn't configured at all —
    /// same opt-in-automation reasoning `CallRecordingCoordinator` used
    /// before this refactor.
    private static func attemptGoogleDrive(filePath: String) async -> (String?, Bool) {
        guard AppSettings.shared.googleServiceAccountPath != nil,
              AppSettings.shared.googleDriveFolderId != nil else {
            print("[UploadOrchestrator] ℹ️ googleServiceAccountPath/googleDriveFolderId не налаштовано — пропускаю Google Drive.")
            return (nil, false)
        }
        do {
            let link = try await GoogleDriveUploadService.upload(filePath: filePath)
            print("[UploadOrchestrator] ✅ запис завантажено в Google Drive — \(link)")
            return (link, false)
        } catch {
            print("[UploadOrchestrator] ❌ не вдалося завантажити запис у Google Drive: \(error)")
            return (nil, true)
        }
    }

    /// Best-effort: a failure here is logged but never turned into
    /// `telegramFailed = true` — the recording is already safely uploaded
    /// to both destinations, this is purely a cosmetic caption fixup, and
    /// treating it as a real failure would make `RecordingHistory` retry
    /// the *whole* entry forever over what's ultimately a non-issue (e.g.
    /// the user deleted the Telegram message in the meantime —
    /// `MESSAGE_ID_INVALID` from TDLib, same case Windows' `EditMessageAsync`
    /// comment calls out).
    private static func patchTelegramCaptionWithDriveLink(messageId: Int64, caption: String, driveUrl: String, authClient: TelegramAuthClient) async {
        guard let chatId = AppSettings.shared.telegramChatId else { return }
        do {
            try await TelegramUploadService.editCaption(
                messageId: messageId, chatId: chatId, caption: caption, driveUrl: driveUrl, authClient: authClient)
            print("[UploadOrchestrator] ✅ підпис у Telegram доповнено посиланням на Google Drive.")
        } catch {
            print("[UploadOrchestrator] ⚠️ не вдалося дописати посилання на Google Drive у вже надіслане повідомлення Telegram: \(error)")
        }
    }

    /// Three-way outcome, not two: not configured (skip, not a failure),
    /// configured but no usable client (login never succeeded — counted as
    /// a failure so the background retry service keeps coming back once
    /// login might work again), or configured with a client (actually try
    /// the send).
    private static func attemptTelegram(filePath: String, caption: String, driveUrl: String?, client: TelegramAuthClient?) async -> (Int64?, Bool) {
        guard AppSettings.shared.telegramChatId != nil else {
            print("[UploadOrchestrator] ℹ️ telegramChatId не налаштовано — пропускаю Telegram.")
            return (nil, false)
        }
        guard let client else {
            print("[UploadOrchestrator] ⚠️ Telegram налаштовано, але клієнт недоступний (авторизація не пройшла) — позначаю як помилку для фонового retry.")
            return (nil, true)
        }
        do {
            let messageId = try await TelegramUploadService.sendRecording(
                filePath: filePath, caption: caption, driveUrl: driveUrl, authClient: client)
            print("[UploadOrchestrator] ✅ запис надіслано в Telegram — messageId=\(messageId).")
            return (messageId, false)
        } catch {
            print("[UploadOrchestrator] ❌ не вдалося надіслати запис у Telegram: \(error)")
            return (nil, true)
        }
    }
}
