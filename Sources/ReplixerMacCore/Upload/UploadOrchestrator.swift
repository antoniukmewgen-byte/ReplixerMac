import Foundation

/// Phase 6: attempts the Drive+Telegram upload steps for a recording,
/// skipping any step that's already succeeded — shared by
/// `CallRecordingCoordinator`'s "just finished recording" path and
/// `PendingUploadRetryService`'s "try the steps that failed last time"
/// path, so the two don't duplicate the same guard/attempt/log logic.
///
/// Windows parity source: `UploadOrchestrator.cs`, scoped down — no
/// `ReportData`/caption-form concept on macOS yet (no Phase 7 UI), so
/// `caption` is passed straight through rather than built from a report
/// form.
///
/// Simplification vs Windows: `UploadOrchestrator.cs`'s `RetryMissingStepsAsync`
/// takes separate `needDrive`/`needTelegram` flags (from
/// `RecordingEntry.DriveFailed`/`TelegramFailed`) to decide what to retry.
/// Here, "already have a value" (`existingDriveUrl`/`existingTelegramMessageId`
/// non-nil) already fully encodes "this step is done, skip it" — a step
/// that was simply never configured stays nil forever and its `*Failed`
/// flag never gets set to true, so `RecordingHistory.needsBackgroundRetry`
/// never selects it in the first place. No separate need-flags required.
///
/// Phase 10.1a rework: Drive is always awaited to completion *first*
/// (matching Windows' own sequencing), then Telegram-send and the Kommo
/// note run *concurrently* — both only need `driveUrl` (already resolved
/// by then) and don't depend on each other. Kommo previously fired as its
/// own independent `Task` straight out of `CallRecordingCoordinator` the
/// moment the call ended, racing Drive and therefore never getting the
/// Drive link in its note text; folding it in here means both destinations
/// get the link inline on the very first attempt, no after-the-fact
/// "edit the message" patch needed for that common case (the Telegram
/// caption-patch path below still exists, but only for the genuine retry
/// edge case: Telegram sent on one attempt while Drive was still down,
/// Drive succeeds on a *later* retry).
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
    /// - Parameter crmUrl: the lead URL from the call report, if one was
    ///   shown and submitted — feeds the Kommo note + call-metadata legs
    ///   only. `nil` means "no report data available" (no report form was
    ///   shown, or this is a `PendingUploadRetryService` retry —
    ///   `RecordingEntry` doesn't persist `crmUrl`, so Kommo can only ever
    ///   be attempted on the *first* pass, never retried; same known gap as
    ///   before this rework, just relocated — see `attemptKommo` below).
    /// - Parameter callStartedAt/callType: Phase 10.1b — feed
    ///   `KommoService.applyCallMetadata`'s first-contact-date/processing-
    ///   speed and call-type/Nedozvon legs. Same nil-on-retry gap as
    ///   `crmUrl` (`RecordingEntry` persists neither).
    /// - Parameter skipTelegram: Windows parity — `PositionPolicy
    ///   .shouldSkipTelegram(position, duration)`, precomputed by the
    ///   caller (it needs the call's role/duration, neither of which this
    ///   stateless type tracks). `true` means "don't send to Telegram at
    ///   all for this recording" — treated as a normal skip, not a
    ///   failure, same as "not configured".
    static func run(
        filePath: String,
        caption: String,
        crmUrl: String?,
        callStartedAt: Date?,
        callType: String?,
        existingDriveUrl: String?,
        existingTelegramMessageId: Int64?,
        telegramClient: TelegramAuthClient?,
        skipTelegram: Bool = false
    ) async -> Result {
        var driveUrl = existingDriveUrl
        var driveFailed = false
        var driveJustSucceeded = false
        if driveUrl == nil {
            (driveUrl, driveFailed) = await attemptGoogleDrive(filePath: filePath)
            driveJustSucceeded = driveUrl != nil
        }

        // driveUrl/driveJustSucceeded are now final for this run — frozen
        // into `let`s here because Swift's concurrency checker won't let
        // `async let` initializers below capture a `var` (even though
        // nothing mutates it after this point, the compiler can't prove
        // that from a `var` declaration alone).
        let resolvedDriveUrl = driveUrl
        let resolvedDriveJustSucceeded = driveJustSucceeded

        // Telegram and Kommo both read the frozen driveUrl below but never
        // race each other or Drive for it.
        async let telegramOutcome: (Int64?, Bool) = resolveTelegram(
            existingMessageId: existingTelegramMessageId,
            driveJustSucceeded: resolvedDriveJustSucceeded,
            filePath: filePath,
            caption: caption,
            driveUrl: resolvedDriveUrl,
            client: telegramClient,
            skipTelegram: skipTelegram
        )
        async let kommoDone: Void = attemptKommo(
            crmUrl: crmUrl, caption: caption, driveUrl: resolvedDriveUrl, callStartedAt: callStartedAt, callType: callType)

        let (telegramMessageId, telegramFailed) = await telegramOutcome
        await kommoDone

        return Result(
            driveUrl: driveUrl,
            driveFailed: driveFailed,
            telegramMessageId: telegramMessageId,
            telegramFailed: telegramFailed
        )
    }

    private static func resolveTelegram(
        existingMessageId: Int64?,
        driveJustSucceeded: Bool,
        filePath: String,
        caption: String,
        driveUrl: String?,
        client: TelegramAuthClient?,
        skipTelegram: Bool
    ) async -> (Int64?, Bool) {
        guard let existingMessageId else {
            return await attemptTelegram(
                filePath: filePath, caption: caption, driveUrl: driveUrl, client: client, skipTelegram: skipTelegram)
        }
        if driveJustSucceeded, let driveUrl, let client {
            // Telegram was already sent by an earlier attempt — at a time
            // when Drive hadn't succeeded yet, so its caption has no Drive
            // link. Drive just succeeded *now* (this run — necessarily a
            // retry, since the first-pass path above always waits for
            // Drive before Telegram even starts), so patch the existing
            // message rather than leaving it permanently missing the link.
            await patchTelegramCaptionWithDriveLink(
                messageId: existingMessageId, caption: caption, driveUrl: driveUrl, authClient: client)
        }
        return (existingMessageId, false)
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
    private static func attemptTelegram(filePath: String, caption: String, driveUrl: String?, client: TelegramAuthClient?, skipTelegram: Bool) async -> (Int64?, Bool) {
        guard !skipTelegram else {
            print("[UploadOrchestrator] ℹ️ роль/тривалість дзвінка не потребують Telegram (PositionPolicy.shouldSkipTelegram) — пропускаю.")
            return (nil, false)
        }
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

    /// Phase 10.1a rework: Kommo note, moved here from
    /// `CallRecordingCoordinator` so it can run concurrently with Telegram
    /// while still only starting *after* Drive resolves — the note text
    /// gets the same "💾 Google Drive: {url}" line Telegram's caption gets
    /// (`TelegramUploadService.buildCaption`'s format, duplicated here
    /// rather than shared — same self-contained-per-integration precedent
    /// as `KommoService.CheckOutcome`), inline on the first attempt, no
    /// separate edit-after-the-fact step the way Telegram sometimes needs.
    ///
    /// Phase 10.1b: the note post and `KommoService.applyCallMetadata`
    /// (first-contact date/processing speed, call-type field, Nedozvon
    /// status advance) are independent writes to the same lead — Windows
    /// parity `KommoService.ProcessLeadAsync` fires them via
    /// `Task.WhenAll`, so this fires them via `async let` rather than
    /// awaiting the note before starting metadata.
    ///
    /// Silently skips (not a failure, nothing returned/tracked in
    /// `Result`) when Kommo isn't configured or there's no `crmUrl` —
    /// same opt-in-automation shape as `attemptGoogleDrive`/`attemptTelegram`.
    /// Still no retry tracking: `RecordingEntry` has no `crmUrl`/
    /// `callStartedAt`/`callType` fields, so `PendingUploadRetryService`
    /// always passes them as `nil` and this simply never fires on a retry —
    /// a failed note/metadata write is logged and dropped, not retried,
    /// same known gap as before this rework.
    private static func attemptKommo(crmUrl: String?, caption: String, driveUrl: String?, callStartedAt: Date?, callType: String?) async {
        guard AppSettings.shared.kommoSubdomain != nil, AppSettings.shared.kommoApiToken != nil else { return }
        guard let crmUrl else { return }
        let text: String = {
            guard let driveUrl, !driveUrl.isEmpty else { return caption }
            return caption + "\n💾 Google Drive: \(driveUrl)"
        }()

        async let noteTask: Void = postKommoNote(crmUrl: crmUrl, text: text)
        async let metadataTask: Void = KommoService.applyCallMetadata(crmUrl: crmUrl, callStartTime: callStartedAt, callType: callType)
        await noteTask
        await metadataTask
    }

    private static func postKommoNote(crmUrl: String, text: String) async {
        do {
            try await KommoService.addNote(crmUrl: crmUrl, text: text)
            print("[UploadOrchestrator] ✅ нотатку додано в Kommo.")
        } catch {
            print("[UploadOrchestrator] ❌ не вдалося додати нотатку в Kommo: \(error)")
        }
    }
}
