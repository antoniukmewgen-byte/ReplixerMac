import Foundation

/// Windows parity source: `RecordingEntry.cs`'s `RecordingStatus` enum,
/// scoped down to states we can actually produce with no upload pipeline
/// yet (`.loading`/`.draft` there exist for the upload-form/upload-retry
/// flow Phase 4-6 will add — not meaningful before that exists).
public enum RecordingStatus: String, Codable {
    /// Call is active, AudioMixerEncoder is currently writing the
    /// `.inprogress` file. An entry left in this state across an app
    /// restart means the process died mid-recording (crash/`kill -9`) —
    /// same signal FileNaming.cleanupStalePartialFiles() acts on for the
    /// file itself; Phase 2.2 doesn't yet reconcile the two, see note in
    /// RecordingHistory.
    case recording
    /// Call ended, AudioMixerEncoder renamed `.inprogress` to its final
    /// name successfully — file exists and is playable.
    case saved
    /// Call ended but the recording pipeline failed somewhere (mix/encode
    /// error, or the final rename itself failed) — no playable file at
    /// `filePath`.
    case error
    /// Phase 11.3 — Windows parity: `RecordingStatus.Draft`. The call
    /// finished and the file is on disk, but the call-report form got
    /// interrupted (a new call arrived, see `CallReportRequestStore
    /// .interrupt()`) before the user submitted it — no upload was
    /// attempted. Whatever was typed so far lives in `reportData`;
    /// `CallRecordingCoordinator.resumeDraft(entryID:)` re-opens the form
    /// prefilled with it and, once actually submitted, runs the same
    /// upload path a normal call-end would have.
    case draft
}

/// A single row in the recordings history (`recordings.json`). Windows
/// parity source: `RecordingEntry.cs`, scoped down to fields Phase 2.2 can
/// actually populate at the time — Drive/Telegram upload-tracking fields
/// were added in Phase 6 now that those integrations (Phase 4/5) exist to
/// populate them. No Kommo field yet (Phase 10, not built).
public struct RecordingEntry: Codable, Identifiable {
    public let id: UUID
    // public internal(set): readable from ReplixerMacApp (Phase 7.4's
    // RecordingsView) but only ever mutated inside this module, exclusively
    // via RecordingHistory's methods — the UI reads snapshots, it never
    // writes entries directly.
    public let platform: String
    public let startedAt: Date
    public internal(set) var filePath: String?
    public internal(set) var status: RecordingStatus
    public internal(set) var callDuration: TimeInterval

    // Phase 6: upload-tracking, Windows parity source RecordingEntry.cs's
    // DriveUrl/TelegramMessageId/DriveFailed/TelegramFailed. Persisted (see
    // CodingKeys) so a background retry — or even an app restart in the
    // middle of one — can pick up exactly where a failed upload left off,
    // without re-running steps that already succeeded (a non-nil
    // driveUrl/telegramMessageId means "already done, don't redo"). Public
    // (Phase 7.4): RecordingsView shows a Drive-link button / Telegram-sent
    // badge when these are set, same as Windows' RecordingItemView.
    public internal(set) var driveUrl: String?
    public internal(set) var telegramMessageId: Int64?
    // "This step was attempted and failed" — distinct from driveUrl/
    // telegramMessageId being nil, which can also mean "not configured,
    // never attempted". Only these flags tell UploadOrchestrator/
    // PendingUploadRetryService what's actually worth retrying. Not needed
    // by the UI yet (entry.status doesn't reflect partial upload failure),
    // stays internal until something actually reads it.
    var driveFailed: Bool
    var telegramFailed: Bool

    // Phase 10.0: the exact Drive/Telegram caption used for this recording
    // (either the submitted call-report's `formatCaption()`, or the
    // generic "Запис дзвінку: {file}" fallback when no report form was
    // shown) — persisted so `retryPendingUploads()` re-sends the *same*
    // text on a later attempt instead of silently reverting to the generic
    // fallback just because the report data itself isn't re-askable after
    // the fact. nil for any entry written before this field existed.
    var caption: String?

    // Transient guard against a slow background-retry tick and a fresh
    // manual retry racing the same entry — deliberately NOT persisted (see
    // CodingKeys/init(from:)/encode(to:) below), same reasoning as Windows'
    // IsBackgroundRetrying.
    var isBackgroundRetrying = false

    init(platform: String, startedAt: Date = Date()) {
        self.id = UUID()
        self.platform = platform
        self.startedAt = startedAt
        self.filePath = nil
        self.status = .recording
        self.callDuration = 0
        self.driveUrl = nil
        self.telegramMessageId = nil
        self.driveFailed = false
        self.telegramFailed = false
        self.caption = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, platform, startedAt, filePath, status, callDuration
        case driveUrl, telegramMessageId, driveFailed, telegramFailed
        case caption
        // isBackgroundRetrying intentionally omitted from CodingKeys — see
        // its doc comment above.
    }

    // Custom Codable (mirrors AppSettings' pattern) instead of relying on
    // synthesis: driveUrl/telegramMessageId/driveFailed/telegramFailed
    // don't exist in any recordings.json written before Phase 6, and
    // synthesized Decodable would hard-fail on every pre-Phase-6 entry
    // rather than defaulting them.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        platform = try container.decode(String.self, forKey: .platform)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
        status = try container.decode(RecordingStatus.self, forKey: .status)
        callDuration = try container.decode(TimeInterval.self, forKey: .callDuration)
        driveUrl = try container.decodeIfPresent(String.self, forKey: .driveUrl)
        telegramMessageId = try container.decodeIfPresent(Int64.self, forKey: .telegramMessageId)
        driveFailed = try container.decodeIfPresent(Bool.self, forKey: .driveFailed) ?? false
        telegramFailed = try container.decodeIfPresent(Bool.self, forKey: .telegramFailed) ?? false
        caption = try container.decodeIfPresent(String.self, forKey: .caption)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(platform, forKey: .platform)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(filePath, forKey: .filePath)
        try container.encode(status, forKey: .status)
        try container.encode(callDuration, forKey: .callDuration)
        try container.encodeIfPresent(driveUrl, forKey: .driveUrl)
        try container.encodeIfPresent(telegramMessageId, forKey: .telegramMessageId)
        try container.encode(driveFailed, forKey: .driveFailed)
        try container.encode(telegramFailed, forKey: .telegramFailed)
        try container.encodeIfPresent(caption, forKey: .caption)
    }

    // Windows parity: RecordingEntry.cs's NeedsBackgroundRetry, scoped down
    // — no ReportData/Kommo concept on macOS yet (no Phase 7 UI, no Phase 10
    // Kommo), so this is just "a step failed, and the local file is still
    // there to retry with" (a step that was simply never configured stays
    // driveFailed/telegramFailed == false forever, so it's never picked up
    // here).
    var needsBackgroundRetry: Bool {
        guard driveFailed || telegramFailed else { return false }
        guard let filePath else { return false }
        return FileManager.default.fileExists(atPath: filePath)
    }
}
