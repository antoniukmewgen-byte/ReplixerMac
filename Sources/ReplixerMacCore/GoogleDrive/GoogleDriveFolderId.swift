import Foundation

/// Sanitizes a user-entered Google Drive folder id, tolerating a full
/// folder URL (`https://drive.google.com/drive/folders/<id>?hl=ru`) the
/// same way `ProfileViewModel.ExtractSpreadsheetId` already tolerates a
/// full Sheets URL on Windows for the Sheets id field — Drive's folder id
/// field never had an equivalent there, and mac inherited that gap.
///
/// Shared (not private to one call site) because a corrupted
/// `AppSettings.shared.googleDriveFolderId` can be exercised from more than
/// one place before a user ever visits `ProfileView` to fix it by hand:
/// `GoogleDriveUploadService.resolveManagerFolder()` runs it during every
/// background call-recording upload from the moment the app launches, and
/// `GoogleDriveFolderAccessSmokeTest`/`GoogleDriveUploadSmokeTest` run it
/// from a bare CLI invocation that never touches SwiftUI at all. All three
/// self-heal `AppSettings.shared.googleDriveFolderId` the moment they see a
/// value `sanitize` had to change, so the fix sticks after the first call
/// that happens to notice it, not just after the next `ProfileView` visit.
///
/// **How this bug actually happened:** a folder id copy-pasted out of a
/// browser URL bar as `1SBELxmGdOQfQgMjeboicuHnexheS44kH?hl=ru` — no
/// `drive.google.com/.../folders/` wrapper, just the bare id with a stray
/// `?hl=ru` still attached — got saved into `googleDriveFolderId` verbatim.
/// `GoogleDriveFolderAccessSmokeTest`'s `files/{id}` GET tolerated the
/// extra text *by accident*: `URLComponents` treats `?` as the start of a
/// URL's query string and splits it off the path before its own explicit
/// query items overwrite whatever was there, so "Перевірити з'єднання"
/// could report success. But `GoogleDriveUploadService`'s folder-resolution
/// code embeds the id as literal text inside a Drive API query *value*
/// (`'<id>' in parents`) and inside JSON request bodies
/// (`"parents": [<id>]`) — neither of those strips a trailing `?...`, so
/// the extra text stayed part of the "id" there and every real upload
/// 404'd against a folder that, with that exact string, doesn't exist.
public enum GoogleDriveFolderId {
    /// Accepts either a bare Drive folder id or a full folder URL and
    /// returns just the id, with any copy-pasted `?...`/`#...` query
    /// string or fragment stripped either way.
    public static func sanitize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if let match = trimmed.range(of: #"/folders/([a-zA-Z0-9_-]+)"#, options: .regularExpression) {
            return String(trimmed[match]).replacingOccurrences(of: "/folders/", with: "")
        }
        // Bare id (no drive.google.com wrapper) but possibly still carrying
        // a copy-pasted "?hl=ru"-style query string or "#..." fragment —
        // strip anything from the first "?"/"#" onward.
        if let cutIndex = trimmed.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            return String(trimmed[trimmed.startIndex..<cutIndex])
        }
        return trimmed
    }

    /// Reads `AppSettings.shared.googleDriveFolderId`, sanitizing and
    /// self-healing the stored value in place if it needed cleanup.
    /// Returns `nil` if unset or blank after trimming — same "not
    /// configured" signal callers already check for on the raw property.
    public static func sanitizedFromSettings() -> String? {
        guard let raw = AppSettings.shared.googleDriveFolderId, !raw.isEmpty else { return nil }
        let sanitized = sanitize(raw)
        if sanitized != raw {
            print("[GoogleDriveFolderId] ℹ️ googleDriveFolderId містив зайві символи (\"\(raw)\") — виправляю на \"\(sanitized)\".")
            AppSettings.shared.googleDriveFolderId = sanitized.isEmpty ? nil : sanitized
        }
        return sanitized.isEmpty ? nil : sanitized
    }
}
