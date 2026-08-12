import Foundation

/// Phase 10.1a — minimal Kommo CRM integration: verifies API connectivity
/// (`GET /account`, for a UI "Перевірити з'єднання" button) and creates a
/// text note on the lead referenced by a call report's `crmUrl`
/// (`POST /leads/{id}/notes`), containing the same caption text already
/// sent to Telegram. Windows parity source: `Services/Upload/KommoService.cs`
/// (~1000 lines), but deliberately scoped down to just the note — the
/// hardcoded custom-field ids (first-contact date, processing-speed
/// minutes, call type, ...) and pipeline/status-stage auto-advance logic
/// tied to that specific Kommo account are Phase 10.1b, not silently
/// dropped. Note text also isn't retroactively patched with the Drive link
/// the way `UploadOrchestrator.patchTelegramCaptionWithDriveLink` does for
/// Telegram — Windows creates the Kommo note only after Drive finishes, but
/// wiring Kommo into that same sequencing is exactly the kind of coupling
/// this minimal slice is deferring; the note goes out immediately with
/// whatever caption was available at call-end time.
public enum KommoService {
    public enum KommoError: Swift.Error {
        case notConfigured
        case invalidLeadURL
        case requestFailed(String)
    }

    /// Stand-in for `Swift.Result<String, String>`, same reasoning as
    /// `GoogleDriveFolderAccessSmokeTest.CheckOutcome` (a bare `String`
    /// failure can't satisfy `Result`'s `Error`-conforming `Failure`
    /// requirement) — declared separately here rather than shared, since
    /// each integration's "test connection" check is its own self-contained
    /// enum with no reason to couple across files.
    public enum CheckOutcome {
        case success(String)
        case failure(String)
    }

    /// Extracts `(subdomain, leadId)` from a Kommo lead-detail URL. Safe to
    /// assume the shape already matches `UrlValidator`'s
    /// `https://<subdomain>.kommo.com/leads/detail/<6+ digits>` pattern —
    /// every call site here only ever receives a `crmUrl` that already
    /// passed `CallReportView.canSubmit`'s validation — but this doesn't
    /// force that assumption; it just returns nil on anything unexpected,
    /// same defensive shape as Windows' `KommoService.ParseLeadUrl`.
    static func parseLeadURL(_ crmUrl: String) -> (subdomain: String, leadId: String)? {
        guard let url = URL(string: crmUrl.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host,
              let subdomain = host.components(separatedBy: ".").first,
              !subdomain.isEmpty
        else { return nil }

        let leadId = url.lastPathComponent
        guard !leadId.isEmpty, Int(leadId) != nil else { return nil }
        return (subdomain, leadId)
    }

    /// Non-interactive connection check for a UI button — same
    /// `check() -> CheckOutcome` shape as `GoogleDriveFolderAccessSmokeTest`,
    /// so ProfileView's Kommo section can reuse the exact same
    /// button/result-label pattern as its Drive section. Reads
    /// `AppSettings.shared.kommoSubdomain` directly (not parsed from a
    /// crmUrl) since this check runs independent of any specific lead/call.
    public static func testConnection() async -> CheckOutcome {
        guard let subdomain = AppSettings.shared.kommoSubdomain?.trimmingCharacters(in: .whitespacesAndNewlines),
              !subdomain.isEmpty else {
            return .failure("У налаштуваннях не заповнено kommoSubdomain.")
        }
        guard let token = AppSettings.shared.kommoApiToken, !token.isEmpty else {
            return .failure("У налаштуваннях не заповнено kommoApiToken.")
        }
        guard let url = URL(string: "https://\(subdomain).kommo.com/api/v4/account") else {
            return .failure("Некоректний kommoSubdomain: \(subdomain).")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let bodyText = String(data: data, encoding: .utf8) ?? "<нечитабельно>"
            guard let http = response as? HTTPURLResponse else {
                return .failure("Неочікувана відповідь без HTTP статусу.")
            }
            if (200...299).contains(http.statusCode) {
                return .success("З'єднання з Kommo (\(subdomain)) підтверджено.")
            } else {
                return .failure("Kommo API повернув статус \(http.statusCode): \(bodyText)")
            }
        } catch {
            return .failure("Запит до Kommo API провалився: \(error)")
        }
    }

    /// Creates a text note on the lead referenced by `crmUrl`. Silently
    /// throws `.notConfigured` (not a crash, not a print) when
    /// `kommoApiToken` is unset — callers treat that exactly like
    /// `CallRecordingCoordinator.telegramClient()` already treats a missing
    /// Telegram token: a normal "integration not opted into" skip, not an
    /// error worth surfacing.
    ///
    /// No retry-on-failure here (unlike `GoogleDriveUploadService.upload`'s
    /// one-retry-after-5s, or `PendingUploadRetryService`'s background
    /// sweep) — deliberately out of scope for this minimal slice; a failed
    /// note is logged by the caller and not tracked anywhere for a later
    /// retry attempt yet.
    public static func addNote(crmUrl: String, text: String) async throws {
        guard let token = AppSettings.shared.kommoApiToken, !token.isEmpty else {
            throw KommoError.notConfigured
        }
        guard let (subdomain, leadId) = parseLeadURL(crmUrl) else {
            throw KommoError.invalidLeadURL
        }
        guard let url = URL(string: "https://\(subdomain).kommo.com/api/v4/leads/\(leadId)/notes") else {
            throw KommoError.invalidLeadURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Windows parity: `POST /leads/{id}/notes` body is an array of note
        // objects — `entity_id` (the lead id, as a number) plus a
        // `note_type: "common"` text note. `entity_id` is technically
        // redundant with the `{id}` already in the URL path, but Windows'
        // `KommoService.AddNoteAsync` sends it explicitly; kept for exact
        // parity rather than relying on it being implied.
        let payload: [[String: Any]] = [[
            "entity_id": Int(leadId) ?? 0,
            "note_type": "common",
            "params": ["text": text],
        ]]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodyText = String(data: data, encoding: .utf8) ?? "<нечитабельно>"
            throw KommoError.requestFailed("статус \(status): \(bodyText)")
        }
    }
}
