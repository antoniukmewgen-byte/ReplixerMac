import Foundation

/// Windows parity source: `ViewModels/Dialogs/MissedCallReportViewModel.cs`'s
/// `MissedCallReportData` record + its `FormatCaption()` method, plus the
/// static `CallTypes` list that lives on `MissedCallReportViewModel` itself
/// there. Same "pure data + pure formatting, no view-model state" shape as
/// `CallReportData` (see that type's doc comment for why this codebase
/// skips formal ViewModel classes).
public struct MissedCallReportData: Codable, Equatable, Sendable {
    public var manager: String
    public var callType: String
    public var crmUrl: String
    /// Compact list (no per-messenger attribution) — feeds the Kommo note
    /// via `formatCaption()`, where screenshot order doesn't matter.
    public var screenshotUrls: [String]
    /// "Час первого касання" for Kommo — defaults to the moment "Не
    /// додзвонився" was clicked, but is editable when `isNoCommunicationType`
    /// (see `MissedCallReportView`).
    public var firstContactTime: Date
    /// Same URLs as `screenshotUrls`, but keyed by messenger ("Viber"/
    /// "Telegram"/"WhatsApp" — see `MessengerDeepLinkProvider
    /// .supportedMessengers`). Windows uses this to route each screenshot
    /// into the right Google-Sheet column; mac has no Sheets integration
    /// (deliberate v1 scope-down, see `MissedCallDeliveryService`'s doc
    /// comment), so this is currently unused by any delivery leg — kept
    /// anyway since `MissedCallReportView`'s per-messenger quick actions
    /// naturally produce it, and it costs nothing to carry through in case
    /// Sheets delivery is added later.
    public var screenshotUrlsByMessenger: [String: String]

    public init(
        manager: String,
        callType: String,
        crmUrl: String,
        screenshotUrls: [String],
        firstContactTime: Date,
        screenshotUrlsByMessenger: [String: String] = [:]
    ) {
        self.manager = manager
        self.callType = callType
        self.crmUrl = crmUrl
        self.screenshotUrls = screenshotUrls
        self.firstContactTime = firstContactTime
        self.screenshotUrlsByMessenger = screenshotUrlsByMessenger
    }

    /// Windows parity source: `MissedCallReportData.FormatCaption()` —
    /// verbatim line-for-line port (same emoji prefixes, same field order).
    public func formatCaption() -> String {
        var lines: [String] = []
        lines.append("📋 Звіт по дзвінку")
        lines.append("")
        lines.append("👤 Менеджер: \(manager)")
        lines.append("📞 Тип дзвінка: \(callType)")
        if !crmUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("🔗 CRM: \(crmUrl)")
        }
        for (index, url) in screenshotUrls.enumerated() {
            lines.append("📎 Скрін \(index + 1) - \(url)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Windows-parity static data (MissedCallReportViewModel.cs)

    public static let callTypes: [String] = [
        "Недозвон 1 (ще не було спілкування)",
        "Недозвон 2 (ще не було спілкування)",
        "Недозвон 3 (ще не було спілкування)",
        "Недозвон 4 (ще не було спілкування)",
        "Недодзвон (вже було спілкування)",
    ]

    /// Windows parity source: `MissedCallReportViewModel.NoCommunicationMarker`
    /// + `IsNoCommunicationType` — substring check (not exact-match against
    /// `callTypes`), since "Недозвон 1..4" all behave identically.
    private static let noCommunicationMarker = "ще не було спілкування"

    public static func isNoCommunicationType(_ callType: String?) -> Bool {
        guard let callType else { return false }
        return callType.contains(noCommunicationMarker)
    }

    public var isNoCommunicationType: Bool { Self.isNoCommunicationType(callType) }

    /// Windows parity source: `RequiredScreenshotCount` — 2 for "ще не було
    /// спілкування" (call + message proof), 1 for "вже було спілкування".
    public var requiredScreenshotCount: Int { isNoCommunicationType ? 2 : 1 }

    /// Windows parity source: `MissedCallReportViewModel.FirstContactTimeFormat`.
    public static let firstContactTimeFormat = "dd.MM.yyyy HH:mm"
}
