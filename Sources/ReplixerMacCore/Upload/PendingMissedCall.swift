import Foundation

/// A single queued missed-call delivery attempt, persisted to
/// `pending_missed_calls.json`. Windows parity source: `Models
/// /PendingMissedCall.cs`, scoped down to the Kommo-only leg mac's v1
/// delivery pipeline actually runs (no `sheetDelivered`/
/// `screenshotUrlsByMessenger`/`processingSpeed*` fields — those only feed
/// Windows' Sheets leg, which has no mac equivalent, see
/// `MissedCallDeliveryService`'s doc comment).
public struct PendingMissedCall: Codable, Equatable {
    public let id: UUID
    public let crmUrl: String
    public let note: String
    public let callType: String?
    public let missedAt: Date
    public let manager: String

    public init(id: UUID, crmUrl: String, note: String, callType: String?, missedAt: Date, manager: String) {
        self.id = id
        self.crmUrl = crmUrl
        self.note = note
        self.callType = callType
        self.missedAt = missedAt
        self.manager = manager
    }
}
