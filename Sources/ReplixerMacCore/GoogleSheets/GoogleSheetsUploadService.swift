import Foundation

/// Phase 15: appends one row per missed call to a user-configured Google
/// Sheet — the macOS/Swift counterpart to Windows'
/// `GoogleSheetsUploadService.cs`. Same "no mature Google API Swift client
/// exists" constraint that led to hand-rolled Drive REST calls
/// (`GoogleDriveUploadService.swift`) applies here too, so this hits the
/// Sheets v4 REST API directly via `URLSession`, authenticated through the
/// same service account as Drive — just a different OAuth scope
/// (`GoogleServiceAccountAuth.sheetsScope`).
///
/// Scope note: on Windows this integration is used ONLY by
/// `MissedCallDeliveryService` (missed-call rows), never by the regular
/// completed-recording upload path — confirmed by grep against
/// `UploadOrchestrator.cs`. Mac mirrors that scoping: nothing here is wired
/// into `CallRecordingCoordinator`/the recording `UploadOrchestrator`.
public enum GoogleSheetsUploadService {
    /// Windows parity: `GoogleSheetsUploadService.cs`'s `SheetHeaders` —
    /// fixed 13-column layout. First 10 are fixed data columns; the last 3
    /// are one-per-messenger screenshot-URL columns, in the exact order of
    /// `MessengerDeepLinkProvider.supportedMessengers`
    /// (`["Viber", "Telegram", "WhatsApp"]`) — callers building a row must
    /// follow that same order, not alphabetical or insertion order.
    static let sheetHeaders: [String] = [
        "Рік", "День", "Місяць", "Час запису", "Менеджер", "Тип дзвінка",
        "Дата дзвінка", "Швидкість, хв", "Швидкість (роб. час), хв",
        "Посилання CRM", "Viber", "Telegram", "WhatsApp"
    ]

    // MARK: - Access check

    /// Windows parity: `TestAccessAsync` — `nil` return means success,
    /// matching the `CheckOutcome`-style "nil error = ok" convention already
    /// used by Drive/Kommo's own "Перевірити з'єднання" checks. Validates
    /// the spreadsheet is reachable with this service account and, if a
    /// sheet/tab name was given, that a tab with that exact name exists.
    public static func testAccess(spreadsheetId: String, sheetName: String) async -> String? {
        let trimmedId = spreadsheetId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else {
            return "Не вказано ID Google Таблиці."
        }
        do {
            let accessToken = try await GoogleServiceAccountAuth.fetchAccessToken(scope: GoogleServiceAccountAuth.sheetsScope)

            var components = URLComponents(string: "https://sheets.googleapis.com/v4/spreadsheets/\(trimmedId)")!
            components.queryItems = [URLQueryItem(name: "fields", value: "properties.title,sheets.properties.title")]
            guard let url = components.url else {
                return "Не вдалося зібрати URL перевірки доступу."
            }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let bodyText = String(data: data, encoding: .utf8) ?? "<нечитабельно>"
                return "Google Таблиці повернули помилку (статус \(status)): \(bodyText)"
            }

            let trimmedSheetName = sheetName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSheetName.isEmpty else { return nil }

            struct SpreadsheetMeta: Decodable {
                struct SheetEntry: Decodable {
                    struct Properties: Decodable { let title: String }
                    let properties: Properties
                }
                let sheets: [SheetEntry]?
            }
            let decoded = try JSONDecoder().decode(SpreadsheetMeta.self, from: data)
            let titles = decoded.sheets?.map { $0.properties.title } ?? []
            guard titles.contains(trimmedSheetName) else {
                return "У таблиці немає аркуша з назвою «\(trimmedSheetName)». Наявні аркуші: \(titles.joined(separator: ", "))."
            }
            return nil
        } catch {
            return "Не вдалося перевірити доступ до Google Таблиці: \(error)"
        }
    }

    // MARK: - Append row

    /// Windows parity: `AppendRowAsync` — returns `(success, isNetworkError,
    /// error)` so callers (`MissedCallDeliveryService`) can distinguish a
    /// transient network failure (worth a background retry) from a hard API
    /// error, same as `GoogleDriveUploadService`'s error surfaces do
    /// implicitly via thrown-error type. Calls `ensureHeaderRow`
    /// unconditionally first, same ordering as Windows.
    public static func appendRow(spreadsheetId: String, sheetName: String, values: [Any?]) async -> (success: Bool, isNetworkError: Bool, error: String?) {
        let trimmedId = spreadsheetId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else {
            return (false, false, "Не вказано ID Google Таблиці.")
        }
        let trimmedSheetName = sheetName.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let accessToken = try await GoogleServiceAccountAuth.fetchAccessToken(scope: GoogleServiceAccountAuth.sheetsScope)
            await ensureHeaderRow(spreadsheetId: trimmedId, sheetName: trimmedSheetName, accessToken: accessToken)

            let range = trimmedSheetName.isEmpty ? "A:A" : trimmedSheetName
            guard let url = valuesURL(
                spreadsheetId: trimmedId,
                range: range,
                extraQuery: [
                    URLQueryItem(name: "valueInputOption", value: "USER_ENTERED"),
                    URLQueryItem(name: "insertDataOption", value: "INSERT_ROWS")
                ],
                suffix: ":append"
            ) else {
                return (false, false, "Не вдалося зібрати URL додавання рядка.")
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["values": [jsonRow(values)]])

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let bodyText = String(data: data, encoding: .utf8) ?? "<нечитабельно>"
                let message = "Google Таблиці повернули помилку (статус \(status)): \(bodyText)"
                print("[GoogleSheetsUploadService] ⚠️ \(message)")
                return (false, false, message)
            }
            return (true, false, nil)
        } catch let error as URLError {
            // Windows distinguishes HttpRequestException/SocketException as
            // "network error, worth a background retry" vs. any other
            // exception as a hard failure — URLError is Foundation's
            // equivalent bucket (offline, timeout, DNS, connection lost…).
            print("[GoogleSheetsUploadService] ⚠️ мережева помилка додавання рядка: \(error)")
            return (false, true, "Мережева помилка: \(error.localizedDescription)")
        } catch {
            print("[GoogleSheetsUploadService] ⚠️ не вдалося додати рядок: \(error)")
            return (false, false, "\(error)")
        }
    }

    private static func jsonRow(_ values: [Any?]) -> [Any] {
        values.map { $0 ?? NSNull() }
    }

    // MARK: - Self-healing header row (Windows parity: EnsureHeaderRowAsync)

    /// Reads `A1:ZZ1`; writes the full header if the row is empty, extends
    /// it with just the missing trailing columns if it's shorter than
    /// `sheetHeaders` (e.g. a new column got added to this enum after the
    /// user's sheet was first created), or no-ops if it's already
    /// full-length. Every failure here is swallowed — non-fatal, same as
    /// Windows — so a header hiccup never blocks the actual data row from
    /// being appended.
    private static func ensureHeaderRow(spreadsheetId: String, sheetName: String, accessToken: String) async {
        let headerRange = sheetName.isEmpty ? "A1:ZZ1" : "\(sheetName)!A1:ZZ1"
        do {
            guard let readURL = valuesURL(spreadsheetId: spreadsheetId, range: headerRange) else { return }
            var readRequest = URLRequest(url: readURL)
            readRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: readRequest)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return
            }

            struct ValuesResponse: Decodable { let values: [[String]]? }
            let decoded = try JSONDecoder().decode(ValuesResponse.self, from: data)
            let existingRow = decoded.values?.first ?? []
            let hasHeader = !existingRow.isEmpty && !(existingRow.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

            if !hasHeader {
                try await writeHeader(spreadsheetId: spreadsheetId, sheetName: sheetName, startColumn: "A", headers: sheetHeaders, accessToken: accessToken)
            } else if existingRow.count < sheetHeaders.count {
                let missing = Array(sheetHeaders.dropFirst(existingRow.count))
                let startColumn = columnLetter(existingRow.count + 1)
                try await writeHeader(spreadsheetId: spreadsheetId, sheetName: sheetName, startColumn: startColumn, headers: missing, accessToken: accessToken)
            }
        } catch {
            print("[GoogleSheetsUploadService] ⚠️ не вдалося перевірити/оновити заголовок таблиці (не критично): \(error)")
        }
    }

    private static func writeHeader(spreadsheetId: String, sheetName: String, startColumn: String, headers: [String], accessToken: String) async throws {
        let range = sheetName.isEmpty ? "\(startColumn)1" : "\(sheetName)!\(startColumn)1"
        guard let url = valuesURL(spreadsheetId: spreadsheetId, range: range, extraQuery: [URLQueryItem(name: "valueInputOption", value: "USER_ENTERED")]) else {
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["values": [headers]])
        _ = try await URLSession.shared.data(for: request)
    }

    /// Standard 1-based-index → spreadsheet-column-letter conversion
    /// (1→A, 26→Z, 27→AA…) — Windows parity: `ColumnLetter`.
    private static func columnLetter(_ index: Int) -> String {
        var n = index
        var result = ""
        while n > 0 {
            let remainder = (n - 1) % 26
            result = String(UnicodeScalar(65 + remainder)!) + result
            n = (n - 1) / 26
        }
        return result.isEmpty ? "A" : result
    }

    // MARK: - URL building

    /// Builds `.../v4/spreadsheets/{id}/values/{range}{suffix}` with
    /// `range` percent-encoded for use in a URL path segment (spaces in a
    /// sheet name, etc.) — `!` and `:` are valid unencoded path characters
    /// per RFC 3986 (`pchar`), so `.urlPathAllowed` leaves them as-is, which
    /// is exactly the literal form Sheets' range syntax
    /// (`SheetName!A1:ZZ1`) expects.
    private static func valuesURL(spreadsheetId: String, range: String, extraQuery: [URLQueryItem] = [], suffix: String = "") -> URL? {
        let encodedRange = range.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? range
        let urlString = "https://sheets.googleapis.com/v4/spreadsheets/\(spreadsheetId)/values/\(encodedRange)\(suffix)"
        guard var components = URLComponents(string: urlString) else { return nil }
        if !extraQuery.isEmpty {
            components.queryItems = extraQuery
        }
        return components.url
    }
}
