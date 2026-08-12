import Foundation

/// Phase 10.1a — minimal Kommo CRM integration: verifies API connectivity
/// (`GET /account`, for a UI "Перевірити з'єднання" button) and creates a
/// text note on the lead referenced by a call report's `crmUrl`
/// (`POST /leads/{id}/notes`), containing the same caption text already
/// sent to Telegram. Windows parity source: `Services/Upload/KommoService.cs`
/// (~1000 lines). Note text isn't retroactively patched with the Drive link
/// the way `UploadOrchestrator.patchTelegramCaptionWithDriveLink` does for
/// Telegram — Windows creates the Kommo note only after Drive finishes, but
/// wiring Kommo into that same sequencing is exactly the kind of coupling
/// this minimal slice is deferring; the note goes out immediately with
/// whatever caption was available at call-end time.
///
/// Phase 10.1b (see `applyCallMetadata` below and everything under its
/// "MARK") adds the hardcoded custom-field/pipeline/status ids this type's
/// doc comment used to call out as deferred — first-contact date,
/// UTC-based processing-speed minutes, the call-type field, and
/// pipeline/status auto-advance into "Недозвон". Still NOT ported: the
/// phone/timezone-derived "робочий час" processing-speed variant (needs a
/// phone-number-parsing dependency mac doesn't have yet — see
/// `trySetFirstContactDate`'s doc comment) and any missed-call-flow
/// equivalent (`MissedCallReportViewModel`'s `NoCommunicationCallTypeMarker`
/// use — mac has no missed-call reporting screen yet, see
/// `MissedCallsView`'s doc comment).
public enum KommoService {
    public enum KommoError: Swift.Error {
        case notConfigured
        case invalidLeadURL
        case requestFailed(String)
    }

    // Phase 10.1b — hardcoded custom-field/pipeline/status ids, Windows
    // parity source: `KommoService.cs`'s own `private const long` block.
    // Tied to this specific Kommo account (same as Windows — not
    // discoverable via API, just copied from a live GET /leads/pipelines
    // response), not meant to be user-configurable.
    private static let firstContactFieldId: Int64 = 1225821
    private static let processingSpeedFieldId: Int64 = 1225823
    private static let callTypeFieldId: Int64 = 1226157
    // Reserved, not yet written by `trySetFirstContactDate` below — see its
    // doc comment for why (needs a phone number + phone→timezone lookup,
    // neither of which macOS has yet).
    private static let processingSpeedLocalTimeFieldId: Int64 = 1227531
    private static let contactPhoneFieldId: Int64 = 458590
    private static let sourceFieldId: Int64 = 1220023
    private static let reactivationEnumId: Int64 = 1028911
    private static let nedozvonPipelineId: Int64 = 12703972
    private static let nedozvonStatusId: Int64 = 98056416
    private static let noCommunicationCallTypeMarker = "ще не було спілкування"

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

    // MARK: - Phase 10.1b: call metadata (first-contact date, processing
    // speed, call type, Nedozvon auto-advance)

    /// Windows parity source: `KommoService.ProcessLeadAsync`'s
    /// date/callType/status legs (the note itself stays on `addNote` above,
    /// called separately by `UploadOrchestrator.attemptKommo` — kept
    /// independent so its own success/failure log line doesn't get muddled
    /// with these). Runs the three legs concurrently, same as Windows'
    /// `Task.WhenAll(dateTask, callTypeTask, statusTask)`. Silently no-ops
    /// (not an error, nothing thrown/returned) when Kommo isn't configured
    /// or `crmUrl` doesn't parse — same opt-in-automation shape as
    /// `addNote`.
    public static func applyCallMetadata(crmUrl: String, callStartTime: Date?, callType: String?) async {
        guard let token = AppSettings.shared.kommoApiToken, !token.isEmpty else { return }
        guard let (subdomain, leadId) = parseLeadURL(crmUrl) else { return }
        let baseURL = "https://\(subdomain).kommo.com/api/v4"

        async let dateTask = resolveProcessingSpeed(baseURL: baseURL, token: token, leadId: leadId, callStartTime: callStartTime)
        async let callTypeTask: Void = applyCallTypeField(baseURL: baseURL, token: token, leadId: leadId, callType: callType)
        async let statusTask: Void = maybeAdvanceNedozvonStatus(baseURL: baseURL, token: token, leadId: leadId, callType: callType)

        _ = await dateTask
        await callTypeTask
        await statusTask
    }

    private static func resolveProcessingSpeed(baseURL: String, token: String, leadId: String, callStartTime: Date?) async -> Int? {
        guard let callStartTime else { return nil }
        return await trySetFirstContactDate(baseURL: baseURL, token: token, leadId: leadId, callStartTime: callStartTime)
    }

    private static func applyCallTypeField(baseURL: String, token: String, leadId: String, callType: String?) async {
        guard let callType, !callType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await patchLeadField(baseURL: baseURL, token: token, leadId: leadId, fieldId: callTypeFieldId, value: callType)
    }

    private static func maybeAdvanceNedozvonStatus(baseURL: String, token: String, leadId: String, callType: String?) async {
        guard let callType, callType.contains(noCommunicationCallTypeMarker) else { return }
        await tryAdvanceToNedozvonStatus(baseURL: baseURL, token: token, leadId: leadId)
    }

    /// Windows parity source: `KommoService.TrySetFirstContactDateAsync`,
    /// minus its phone/timezone-derived "робочий час" leg
    /// (`ProcessingSpeedLocalTimeFieldId`) — that needs a phone number
    /// resolved from the lead's Kommo contact/company plus a
    /// phone-number→IANA-timezone lookup (Windows: libphonenumber's
    /// `PhoneNumberToTimeZonesMapper`), and mac has no phone-number-parsing
    /// dependency yet (see `Package.swift`). Deliberately deferred, not
    /// silently dropped: `processingSpeedLocalTimeFieldId` simply never gets
    /// written by this port yet, same "known gap, revisit later" shape as
    /// `UploadOrchestrator.attemptKommo`'s retry-tracking gap.
    ///
    /// Never overwrites a field that already has *any* non-empty value
    /// (`firstContactOccupied`/`speedMinutesOccupied` below) — someone may
    /// have filled it in by hand in Kommo's UI already.
    private static func trySetFirstContactDate(baseURL: String, token: String, leadId: String, callStartTime: Date) async -> Int? {
        let details = await getLeadDetails(baseURL: baseURL, token: token, leadId: leadId)

        let firstContactUnix: Int64?
        if details.firstContactOccupied {
            firstContactUnix = details.firstContactUnix
        } else {
            let unix = Int64(callStartTime.timeIntervalSince1970)
            firstContactUnix = unix
            await patchLeadField(baseURL: baseURL, token: token, leadId: leadId, fieldId: firstContactFieldId, value: unix)
        }

        // "Реактивация" — лід уже був у роботі раніше, тож "швидкість першого
        // касання" не показник (це не реакція на нове звернення) — пишемо 0
        // замість розрахунку, з тим самим "не чіпаємо, якщо вже зайняте" захистом.
        if details.isReactivationSource {
            if details.speedMinutesOccupied { return details.speedMinutes }
            await patchLeadField(baseURL: baseURL, token: token, leadId: leadId, fieldId: processingSpeedFieldId, value: 0)
            return 0
        }

        if details.speedMinutesOccupied { return details.speedMinutes }
        guard let createdAt = details.createdAt, let firstContactUnix else { return nil }

        let minutes = Int((Double(abs(createdAt - firstContactUnix)) / 60).rounded())
        await patchLeadField(baseURL: baseURL, token: token, leadId: leadId, fieldId: processingSpeedFieldId, value: minutes)
        return minutes
    }

    private struct LeadDetails {
        var createdAt: Int64?
        var firstContactUnix: Int64?
        var firstContactOccupied = false
        var contactId: String?
        var companyId: String?
        var speedMinutes: Int?
        var speedMinutesOccupied = false
        var isReactivationSource = false
    }

    /// Windows parity source: `KommoService.GetLeadDetailsAsync`, scoped
    /// down to what `trySetFirstContactDate` above actually reads —
    /// `speedWorkMinutes`/`speedWorkMinutesOccupied` aren't tracked since
    /// nothing here writes `processingSpeedLocalTimeFieldId` yet.
    /// `"with=contacts,companies,custom_fields"` still requested (not just
    /// `custom_fields`) so `contactId`/`companyId` are already threaded
    /// through for whenever the phone/timezone leg gets built.
    private static func getLeadDetails(baseURL: String, token: String, leadId: String) async -> LeadDetails {
        guard let url = URL(string: "\(baseURL)/leads/\(leadId)?with=contacts,companies,custom_fields") else {
            return LeadDetails()
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("[KommoService] ❌ GetLeadDetails HTTP \(status) — лід \(leadId).")
                return LeadDetails()
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return LeadDetails()
            }

            var details = LeadDetails()
            details.createdAt = (json["created_at"] as? NSNumber)?.int64Value

            if let fields = json["custom_fields_values"] as? [[String: Any]] {
                for field in fields {
                    guard let fieldId = (field["field_id"] as? NSNumber)?.int64Value else { continue }

                    // "Источник" — цікавить не value (текст), а enum_id (яка саме
                    // опція обрана), перевіряємо окремо від числових полів нижче.
                    if fieldId == sourceFieldId {
                        if let values = field["values"] as? [[String: Any]] {
                            for v in values {
                                if let enumId = (v["enum_id"] as? NSNumber)?.int64Value, enumId == reactivationEnumId {
                                    details.isReactivationSource = true
                                    break
                                }
                            }
                        }
                        continue
                    }

                    guard fieldId == firstContactFieldId || fieldId == processingSpeedFieldId else { continue }
                    guard let values = field["values"] as? [[String: Any]],
                          let occupied = Self.firstOccupiedValue(in: values) else { continue }

                    let numericValue: Int64? = {
                        if let n = occupied as? NSNumber { return n.int64Value }
                        if let s = occupied as? String { return Int64(s) }
                        return nil
                    }()

                    if fieldId == firstContactFieldId {
                        details.firstContactOccupied = true
                        details.firstContactUnix = numericValue
                    } else {
                        details.speedMinutesOccupied = true
                        details.speedMinutes = numericValue.map(Int.init)
                    }
                }
            }

            if let embedded = json["_embedded"] as? [String: Any] {
                if let contacts = embedded["contacts"] as? [[String: Any]] {
                    for c in contacts {
                        guard let id = (c["id"] as? NSNumber)?.int64Value else { continue }
                        let isMain = (c["is_main"] as? Bool) == true
                        if isMain || details.contactId == nil { details.contactId = String(id) }
                        if isMain { break }
                    }
                }
                if let companies = embedded["companies"] as? [[String: Any]],
                   let first = companies.first,
                   let id = (first["id"] as? NSNumber)?.int64Value {
                    details.companyId = String(id)
                }
            }

            return details
        } catch {
            print("[KommoService] ❌ GetLeadDetails виняток — лід \(leadId): \(error)")
            return LeadDetails()
        }
    }

    /// Поле вважається "вже заповненим", якщо в ньому лежить будь-яке
    /// непорожнє число чи непорожній текст — тільки ці два JSON-типи
    /// зустрічаються в трьох полях, які тут читаються (дата-таймстамп чи
    /// хвилини, обидва числові; текст — на випадок ручного вводу не тим
    /// типом). Windows' `TryGetOccupiedValue` також враховує bool (`True`/
    /// `False` завжди "зайнято") — жодне з полів тут ніколи не буває
    /// булевим, тож той випадок свідомо не портується.
    private static func firstOccupiedValue(in values: [[String: Any]]) -> Any? {
        for v in values {
            guard let value = v["value"] else { continue }
            if let n = value as? NSNumber, n.int64Value != 0 { return value }
            if let s = value as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
        }
        return nil
    }

    private static func patchLeadField(baseURL: String, token: String, leadId: String, fieldId: Int64, value: Any) async {
        guard let url = URL(string: "\(baseURL)/leads/\(leadId)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "custom_fields_values": [
                ["field_id": fieldId, "values": [["value": value]]]
            ]
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let bodyText = String(data: data, encoding: .utf8) ?? "<нечитабельно>"
                print("[KommoService] ❌ PatchLeadField \(fieldId) HTTP \(status) — лід \(leadId): \(bodyText)")
                return
            }
        } catch {
            print("[KommoService] ❌ PatchLeadField \(fieldId) виняток — лід \(leadId): \(error)")
        }
    }

    // Угода не рухається назад по воронці: якщо вона вже в тій самій воронці
    // "Відділ продажу ЕК", але на стадії, що йде ПІСЛЯ "Недозвону", менеджер
    // вже просунув її далі — пропускаємо зміну статусу. Windows parity
    // source: `KommoService.TryAdvanceToNedozvonStatusAsync`. При будь-якій
    // помилці визначення поточної позиції — застосовуємо статус як і до
    // цієї перевірки (безпечніший дефолт, ніж мовчки нічого не зробити) —
    // тут це виходить "з коробки", бо getLeadPipelineStatus/
    // getPipelineStatusSortOrder повертають nil замість кидати помилку.
    private static func tryAdvanceToNedozvonStatus(baseURL: String, token: String, leadId: String) async {
        let (currentPipelineId, currentStatusId) = await getLeadPipelineStatus(baseURL: baseURL, token: token, leadId: leadId)

        if currentPipelineId == nedozvonPipelineId, let currentStatusId, currentStatusId != nedozvonStatusId {
            if let sortById = await getPipelineStatusSortOrder(baseURL: baseURL, token: token, pipelineId: nedozvonPipelineId),
               let currentSort = sortById[currentStatusId],
               let nedozvonSort = sortById[nedozvonStatusId],
               currentSort > nedozvonSort {
                print("[KommoService] ℹ️ лід \(leadId) вже на стадії після 'Недозвону' — статус не змінюю.")
                return
            }
        }

        await patchLeadStatus(baseURL: baseURL, token: token, leadId: leadId, statusId: nedozvonStatusId, pipelineId: nedozvonPipelineId)
    }

    private static func getLeadPipelineStatus(baseURL: String, token: String, leadId: String) async -> (pipelineId: Int64?, statusId: Int64?) {
        guard let url = URL(string: "\(baseURL)/leads/\(leadId)") else { return (nil, nil) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (nil, nil)
            }
            return ((json["pipeline_id"] as? NSNumber)?.int64Value, (json["status_id"] as? NSNumber)?.int64Value)
        } catch {
            print("[KommoService] ❌ GetLeadPipelineStatus виняток — лід \(leadId): \(error)")
            return (nil, nil)
        }
    }

    // sort — офіційне поле Kommo, що визначає порядок стадій у воронці
    // (менше значення = раніше).
    private static func getPipelineStatusSortOrder(baseURL: String, token: String, pipelineId: Int64) async -> [Int64: Int]? {
        guard let url = URL(string: "\(baseURL)/leads/pipelines/\(pipelineId)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let embedded = json["_embedded"] as? [String: Any],
                  let statuses = embedded["statuses"] as? [[String: Any]] else {
                return nil
            }
            var result: [Int64: Int] = [:]
            for status in statuses {
                if let id = (status["id"] as? NSNumber)?.int64Value, let sort = (status["sort"] as? NSNumber)?.intValue {
                    result[id] = sort
                }
            }
            return result
        } catch {
            print("[KommoService] ❌ GetPipelineStatusSortOrder виняток — воронка \(pipelineId): \(error)")
            return nil
        }
    }

    // status_id/pipeline_id — поля верхнього рівня самого ліда (на відміну
    // від custom_fields_values, які патчить patchLeadField вище).
    private static func patchLeadStatus(baseURL: String, token: String, leadId: String, statusId: Int64, pipelineId: Int64) async {
        guard let url = URL(string: "\(baseURL)/leads/\(leadId)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = ["status_id": statusId, "pipeline_id": pipelineId]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let bodyText = String(data: data, encoding: .utf8) ?? "<нечитабельно>"
                print("[KommoService] ❌ PatchLeadStatus HTTP \(status) — лід \(leadId): \(bodyText)")
                return
            }
        } catch {
            print("[KommoService] ❌ PatchLeadStatus виняток — лід \(leadId): \(error)")
        }
    }
}
