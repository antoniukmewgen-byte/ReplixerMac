import Foundation

/// Windows parity source: `RecordingEntry.cs`'s `RecordingStatus` enum,
/// scoped down to states we can actually produce with no upload pipeline
/// yet (`.loading`/`.draft` there exist for the upload-form/upload-retry
/// flow Phase 4-6 will add — not meaningful before that exists).
enum RecordingStatus: String, Codable {
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
}

/// A single row in the recordings history (`recordings.json`). Windows
/// parity source: `RecordingEntry.cs`, scoped down to fields Phase 2.2 can
/// actually populate at the time — Drive/Telegram upload-tracking fields
/// were added in Phase 6 now that those integrations (Phase 4/5) exist to
/// populate them. No Kommo field yet (Phase 10, not built).
struct RecordingEntry: Codable, Identifiable {
    let id: UUID
    let platform: String
    let startedAt: Date
    var filePath: String?
    var status: RecordingStatus
    var callDuration: TimeInterval

    // Phase 6: upload-tracking, Windows parity source RecordingEntry.cs's
    // DriveUrl/TelegramMessageId/DriveFailed/TelegramFailed. Persisted (see
    // CodingKeys) so a background retry — or even an app restart in the
    // middle of one — can pick up exactly where a failed upload left off,
    // without re-running steps that already succeeded (a non-nil
    // driveUrl/telegramMessageId means "already done, don't redo").
    var driveUrl: String?
    var telegramMessageId: Int64?
    // "This step was attempted and failed" — distinct from driveUrl/
    // telegramMessageId being nil, which can also mean "not configured,
    // never attempted". Only these flags tell UploadOrchestrator/
    // PendingUploadRetryService what's actually worth retrying.
    var driveFailed: Bool
    var telegramFailed: Bool

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
    }

    private enum CodingKeys: String, CodingKey {
        case id, platform, startedAt, filePath, status, callDuration
        case driveUrl, telegramMessageId, driveFailed, telegramFailed
        // isBackgroundRetrying intentionally omitted from CodingKeys — see
        // its doc comment above.
    }

    // Custom Codable (mirrors AppSettings' pattern) instead of relying on
    // synthesis: driveUrl/telegramMessageId/driveFailed/telegramFailed
    // don't exist in any recordings.json written before Phase 6, and
    // synthesized Decodable would hard-fail on every pre-Phase-6 entry
    // rather than defaulting them.
    init(from decoder: Decoder) throws {
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
    }

    func encode(to encoder: Encoder) throws {
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
