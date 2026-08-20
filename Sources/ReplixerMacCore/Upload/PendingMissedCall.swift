import Foundation

/// A single queued missed-call delivery attempt, persisted to
/// `pending_missed_calls.json`. Windows parity source: `Models
/// /PendingMissedCall.cs`.
///
/// Phase 15: now carries the same two-independent-delivery-targets shape as
/// Windows — `kommoDelivered`/`sheetDelivered` are tracked separately (an
/// entry can have Kommo delivered but still be queued purely for the Sheets
/// leg to catch up, or vice versa on a fresh retry after a partial
/// success), and `processingSpeedMinutes`/`processingSpeedWorkMinutes` are
/// cached here once Kommo computes them so a later-in-time Sheets delivery
/// doesn't need to re-hit Kommo's API just to read them back.
/// `screenshotUrlsByMessenger` carries `MissedCallReportData`'s per-
/// messenger screenshot URLs through to `BuildSheetRow`-equivalent row
/// construction (`MissedCallDeliveryService.buildSheetRow`).
///
/// A plain `struct` with `var` fields (not a Swift `enum`-of-cases or an
/// immutable `let`-only shape) so call sites can mutate-in-place the same
/// way Windows' `record ... with { ... }` expressions do — `Equatable`
/// still holds trivially since every field remains value-comparable.
public struct PendingMissedCall: Codable, Equatable {
    public let id: UUID
    public let crmUrl: String
    public let note: String
    public let callType: String?
    public let missedAt: Date
    public let manager: String
    public var screenshotUrlsByMessenger: [String: String]
    public var kommoDelivered: Bool
    public var sheetDelivered: Bool
    public var processingSpeedMinutes: Int?
    public var processingSpeedWorkMinutes: Int?

    public init(
        id: UUID,
        crmUrl: String,
        note: String,
        callType: String?,
        missedAt: Date,
        manager: String,
        screenshotUrlsByMessenger: [String: String] = [:],
        kommoDelivered: Bool = false,
        sheetDelivered: Bool = false,
        processingSpeedMinutes: Int? = nil,
        processingSpeedWorkMinutes: Int? = nil
    ) {
        self.id = id
        self.crmUrl = crmUrl
        self.note = note
        self.callType = callType
        self.missedAt = missedAt
        self.manager = manager
        self.screenshotUrlsByMessenger = screenshotUrlsByMessenger
        self.kommoDelivered = kommoDelivered
        self.sheetDelivered = sheetDelivered
        self.processingSpeedMinutes = processingSpeedMinutes
        self.processingSpeedWorkMinutes = processingSpeedWorkMinutes
    }

    // Backward-compatible decode: a `pending_missed_calls.json` written
    // before Phase 15 has none of the new keys — default them to "nothing
    // delivered yet, no speed cached, no per-messenger map", which is
    // exactly the state a freshly-submitted (Kommo-only) entry would have
    // had under the old shape.
    private enum CodingKeys: String, CodingKey {
        case id, crmUrl, note, callType, missedAt, manager
        case screenshotUrlsByMessenger, kommoDelivered, sheetDelivered
        case processingSpeedMinutes, processingSpeedWorkMinutes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        crmUrl = try container.decode(String.self, forKey: .crmUrl)
        note = try container.decode(String.self, forKey: .note)
        callType = try container.decodeIfPresent(String.self, forKey: .callType)
        missedAt = try container.decode(Date.self, forKey: .missedAt)
        manager = try container.decode(String.self, forKey: .manager)
        screenshotUrlsByMessenger = try container.decodeIfPresent([String: String].self, forKey: .screenshotUrlsByMessenger) ?? [:]
        kommoDelivered = try container.decodeIfPresent(Bool.self, forKey: .kommoDelivered) ?? false
        sheetDelivered = try container.decodeIfPresent(Bool.self, forKey: .sheetDelivered) ?? false
        processingSpeedMinutes = try container.decodeIfPresent(Int.self, forKey: .processingSpeedMinutes)
        processingSpeedWorkMinutes = try container.decodeIfPresent(Int.self, forKey: .processingSpeedWorkMinutes)
    }
}
