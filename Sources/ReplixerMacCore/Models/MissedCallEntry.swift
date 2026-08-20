import Foundation

/// A single row in the missed-calls history (`missed_calls.json`). Windows
/// parity source: `Models/MissedCallEntry.cs`.
///
/// - `INotifyPropertyChanged`'s live-updating `StatusText` has no SwiftUI
///   equivalent needed — `MissedCallsView` mirrors `MissedCallHistory
///   .entries` into `@State` on `didChangeNotification`, same pattern as
///   `RecordingEntry`/`RecordingsView`, so `statusText` just needs to be a
///   plain computed property re-read on refresh.
public struct MissedCallEntry: Codable, Identifiable {
    public let id: UUID
    public let manager: String
    public let callType: String
    public let missedAt: Date
    public let crmUrl: String
    public internal(set) var screenshotUrls: [String]
    /// True once `MissedCallDeliveryService` has posted the Kommo note for
    /// this entry — drives `statusText` below. Windows parity:
    /// `MissedCallEntry.KommoDelivered`.
    public internal(set) var kommoDelivered: Bool
    /// Phase 15: true once `MissedCallDeliveryService` has also appended
    /// this entry's row to the configured Google Sheet (independent of
    /// `kommoDelivered` — see `PendingMissedCall`'s doc comment for why the
    /// two legs are tracked separately). Windows parity:
    /// `MissedCallEntry.SheetDelivered`. Deliberately NOT part of
    /// `statusText` below — Windows' own `StatusText` only checks
    /// `_kommoDelivered` too, so this stays a plain tracking field with no
    /// UI-visible status-text effect, matching that behavior exactly.
    public internal(set) var sheetDelivered: Bool

    public init(
        id: UUID = UUID(),
        manager: String,
        callType: String,
        missedAt: Date,
        crmUrl: String,
        screenshotUrls: [String]
    ) {
        self.id = id
        self.manager = manager
        self.callType = callType
        self.missedAt = missedAt
        self.crmUrl = crmUrl
        self.screenshotUrls = screenshotUrls
        self.kommoDelivered = false
        self.sheetDelivered = false
    }

    // Backward-compatible decode: a `missed_calls.json` written before
    // Phase 15 has no `sheetDelivered` key — default it to false (matches
    // this init's own default above) rather than failing to decode the
    // whole history file over one new field.
    private enum CodingKeys: String, CodingKey {
        case id, manager, callType, missedAt, crmUrl, screenshotUrls, kommoDelivered, sheetDelivered
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        manager = try container.decode(String.self, forKey: .manager)
        callType = try container.decode(String.self, forKey: .callType)
        missedAt = try container.decode(Date.self, forKey: .missedAt)
        crmUrl = try container.decode(String.self, forKey: .crmUrl)
        screenshotUrls = try container.decode([String].self, forKey: .screenshotUrls)
        kommoDelivered = try container.decodeIfPresent(Bool.self, forKey: .kommoDelivered) ?? false
        sheetDelivered = try container.decodeIfPresent(Bool.self, forKey: .sheetDelivered) ?? false
    }

    /// Windows parity source: `MissedCallEntry.StatusText` — checks only
    /// `kommoDelivered`, same as Windows' own implementation (see
    /// `sheetDelivered`'s doc comment above for why Sheets status doesn't
    /// factor in here).
    public var statusText: String { kommoDelivered ? "Відправлено" : "У черзі" }

    /// Windows parity source: `MissedCallEntry.HasManager`.
    public var hasManager: Bool { !manager.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
