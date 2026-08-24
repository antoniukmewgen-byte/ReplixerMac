import Foundation

/// Windows parity source: `Infrastructure/CaptionHelper.cs` — a caption may
/// end with a trailing "#hashtag" line (`CallReportData.formatCaption()`'s
/// `"\n#оплата"` suffix is the one case that currently produces one).
/// Telegram keeps that line, just reordered to sit right before the version
/// tag (see `TelegramUploadService.buildCaption`); Kommo notes drop it
/// entirely (see `UploadOrchestrator.attemptKommo` /
/// `CallRecordingCoordinator.editKommoNote`) since a hashtag is a
/// Telegram-only tagging convention, not something a CRM note body should
/// contain.
enum CaptionHelper {
    /// Splits off a trailing line that starts with "#", if the caption ends
    /// with one. Returns `(caption, nil)` unchanged otherwise.
    static func splitHashtagSuffix(_ caption: String) -> (body: String, hashtagLine: String?) {
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let newlineIndex = trimmed.lastIndex(of: "\n") else {
            return (trimmed, nil)
        }
        var lastLine = String(trimmed[trimmed.index(after: newlineIndex)...])
        while lastLine.hasPrefix("\r") {
            lastLine.removeFirst()
        }
        guard lastLine.hasPrefix("#") else {
            return (trimmed, nil)
        }
        let body = String(trimmed[..<newlineIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (body, lastLine)
    }

    static func stripHashtags(_ caption: String) -> String {
        splitHashtagSuffix(caption).body
    }
}
