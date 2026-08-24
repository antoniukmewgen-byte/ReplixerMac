import Foundation

/// One local screenshot (captured via the missed-call report's "Швидкі дії"
/// buttons) that failed an immediate Google Drive upload and is waiting for
/// `ScreenshotUploadRetryService`'s background retry — same role
/// `PendingMissedCall` plays for `MissedCallDeliveryService`. Windows parity
/// source: `Models/PendingScreenshotUpload.cs`.
///
/// `folderId` is `nil` when even folder *resolution* failed before upload
/// was attempted (Windows still queues in that case, retrying with a null
/// folder id forever — `ScreenshotUploadRetryService` instead re-resolves
/// the folder on each attempt when this is `nil`, see its doc comment).
/// `kommoLeadUrl` — if the missed-call report form gets submitted before
/// this screenshot finishes uploading in the background, the link isn't
/// lost: once the upload succeeds, a separate Kommo note with the late link
/// gets posted to this lead instead of trying to retroactively patch the
/// already-sent report note.
public struct PendingScreenshotUpload: Codable, Equatable {
    public let id: UUID
    public let localPath: String
    public let folderId: String?
    public let messenger: String
    public let kommoLeadUrl: String?
    public let capturedAt: Date

    public init(id: UUID, localPath: String, folderId: String?, messenger: String, kommoLeadUrl: String?, capturedAt: Date) {
        self.id = id
        self.localPath = localPath
        self.folderId = folderId
        self.messenger = messenger
        self.kommoLeadUrl = kommoLeadUrl
        self.capturedAt = capturedAt
    }
}
