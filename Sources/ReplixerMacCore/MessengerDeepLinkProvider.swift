import Foundation

/// Windows parity source: `Infrastructure/MessengerDeepLinkProvider.cs` —
/// near-verbatim port (same three deep-link URL templates, same
/// leading-`+`/space/dash stripping before substitution). Used by
/// `MissedCallReportView`'s per-messenger "quick action" buttons to open a
/// chat with the client straight from their phone number (resolved via
/// `KommoService.getClientPhone`).
public enum MessengerDeepLinkProvider {
    private static let templates: [String: String] = [
        "Viber": "viber://chat?number=%2B{phone}",
        "Telegram": "tg://resolve?phone={phone}",
        "WhatsApp": "whatsapp://send?phone={phone}",
    ]

    /// Windows parity source: `MessengerDeepLinkProvider.SupportedMessengers`.
    public static let supportedMessengers: [String] = ["Viber", "Telegram", "WhatsApp"]

    /// Builds a deep link for `messenger` and `phone`, or `nil` if
    /// `messenger` isn't one of `supportedMessengers`. `phone` is normalized
    /// first — strips a leading `+`, spaces, and dashes, same as Windows
    /// (Kommo phone fields are free text and can come back in any of those
    /// shapes).
    public static func buildDeepLink(messenger: String, phone: String) -> URL? {
        guard let template = templates[messenger] else { return nil }
        var normalized = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("+") {
            normalized.removeFirst()
        }
        normalized = normalized.replacingOccurrences(of: " ", with: "")
        normalized = normalized.replacingOccurrences(of: "-", with: "")
        let urlString = template.replacingOccurrences(of: "{phone}", with: normalized)
        return URL(string: urlString)
    }
}
