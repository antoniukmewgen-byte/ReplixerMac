import Foundation

/// Sanitizes a user-entered Google Sheets spreadsheet id, tolerating a full
/// spreadsheet URL (`https://docs.google.com/spreadsheets/d/<id>/edit#gid=0`)
/// the same way `GoogleDriveFolderId.sanitize` tolerates a full Drive folder
/// URL — Windows parity source: `ProfileViewModel.ExtractSpreadsheetId`
/// (regex `/spreadsheets/d/([a-zA-Z0-9_-]+)`), which Mac never ported until
/// now (the Google Sheets section was a Phase 10 placeholder before Phase
/// 15). Mirrors `GoogleDriveFolderId`'s exact shape — same reasoning for
/// stripping a stray `?...`/`#...` off a bare id copy-pasted without the
/// `/edit#gid=0` suffix trimmed.
public enum GoogleSheetsId {
    /// Accepts either a bare spreadsheet id or a full spreadsheet URL and
    /// returns just the id, with any copy-pasted `?...`/`#...` query string
    /// or fragment stripped either way.
    public static func sanitize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if let match = trimmed.range(of: #"/spreadsheets/d/([a-zA-Z0-9_-]+)"#, options: .regularExpression) {
            return String(trimmed[match]).replacingOccurrences(of: "/spreadsheets/d/", with: "")
        }
        // Bare id (no docs.google.com wrapper) but possibly still carrying a
        // copy-pasted "?..."/"#..." fragment — strip anything from the first
        // "?"/"#" onward.
        if let cutIndex = trimmed.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            return String(trimmed[trimmed.startIndex..<cutIndex])
        }
        return trimmed
    }

    /// Reads `AppSettings.shared.googleSheetsId`, sanitizing and self-healing
    /// the stored value in place if it needed cleanup. Returns `nil` if
    /// unset or blank after trimming — same "not configured" signal callers
    /// already check for on the raw property.
    public static func sanitizedFromSettings() -> String? {
        guard let raw = AppSettings.shared.googleSheetsId, !raw.isEmpty else { return nil }
        let sanitized = sanitize(raw)
        if sanitized != raw {
            print("[GoogleSheetsId] ℹ️ googleSheetsId містив зайві символи (\"\(raw)\") — виправляю на \"\(sanitized)\".")
            AppSettings.shared.googleSheetsId = sanitized.isEmpty ? nil : sanitized
        }
        return sanitized.isEmpty ? nil : sanitized
    }
}
