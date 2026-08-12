import Foundation

/// Windows parity source: `Infrastructure/UrlValidator.cs` — verbatim port.
/// Deliberately narrower than "any http(s) URL": `CallReportView`'s CRM-link
/// field is specifically a Kommo lead-detail link, and Windows found in
/// practice that managers sometimes paste a truncated link (clipboard race,
/// hit Submit before the paste finished) that still "looks like a URL" —
/// silently accepting that would attach the report to the wrong lead (Kommo
/// IDs are one global counter across the whole account), or to no lead at
/// all. Matching the exact `https://<subdomain>.kommo.com/leads/detail/<8+
/// digits>` shape catches that class of mistake instead of merely checking
/// "is this parseable as a URL".
public enum UrlValidator {
    // 6+ digits — verbatim threshold from the Windows regex (see its
    // comment: real IDs are 8 digits today, 6 leaves headroom as Kommo's
    // account-wide ID counter grows). Kept identical rather than
    // tightened, per "full parity with Windows" — this is Windows' call to
    // revisit, not a mac-side deviation.
    private static let kommoLeadUrlPattern =
        #"^https://[a-zA-Z0-9\-]+\.kommo\.com/leads/detail/\d{6,}"#

    public static func isValidHttpUrl(_ url: String?) -> Bool {
        guard let url else { return false }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.range(of: kommoLeadUrlPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
