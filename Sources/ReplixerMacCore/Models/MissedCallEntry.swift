import Foundation

/// A single row in the missed-calls history (`missed_calls.json`). Windows
/// parity source: `Models/MissedCallEntry.cs`, scoped down to what mac's v1
/// delivery pipeline can actually populate:
///
/// - No `sheetDelivered` — mac has no Google Sheets integration at all
///   (deliberate scope-down, see `MissedCallDeliveryService`'s doc comment),
///   unlike Windows' Kommo-then-Sheets two-leg delivery. `kommoDelivered`
///   alone drives `statusText` here.
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
    }

    /// Windows parity source: `MissedCallEntry.StatusText`, scoped down to
    /// the single Kommo leg (see type doc comment above for why there's no
    /// Sheets leg to also check here).
    public var statusText: String { kommoDelivered ? "Відправлено" : "У черзі" }

    /// Windows parity source: `MissedCallEntry.HasManager`.
    public var hasManager: Bool { !manager.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
