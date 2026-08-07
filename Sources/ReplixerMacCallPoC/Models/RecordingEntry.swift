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
/// actually populate — Drive/Telegram/Kommo upload-tracking fields will be
/// added in Phase 4-6 once those integrations exist to populate them.
struct RecordingEntry: Codable, Identifiable {
    let id: UUID
    let platform: String
    let startedAt: Date
    var filePath: String?
    var status: RecordingStatus
    var callDuration: TimeInterval

    init(platform: String, startedAt: Date = Date()) {
        self.id = UUID()
        self.platform = platform
        self.startedAt = startedAt
        self.filePath = nil
        self.status = .recording
        self.callDuration = 0
    }
}
