import Foundation
import PhoneNumberKit

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
/// pipeline/status auto-advance into "Недозвон".
///
/// Phase 10.1c adds the one leg 10.1b deliberately left out: the
/// phone/timezone-derived "робочий час" processing-speed variant
/// (`trySetLocalTimeProcessingSpeed` below), using `PhoneNumberKit` (added
/// to `Package.swift` this phase) for phone parsing plus, as of the
/// 10.1c revision, `NANPTimeZoneMapper` — a Swift port of the same
/// libphonenumber geocoder data Windows' `libphonenumber-csharp` dependency
/// reads — for the actual zone lookup, in place of the original
/// hand-maintained per-area-code table. See both types' doc comments for
/// exactly where fidelity is still scoped down (non-US/non-Ukrainian
/// numbers).
///
/// Still NOT ported: any missed-call-flow equivalent
/// (`MissedCallReportViewModel`'s `NoCommunicationCallTypeMarker` use — mac
/// has no missed-call reporting screen yet, see `MissedCallsView`'s doc
/// comment).
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
    // Phase 10.1c: "Скорость обработки в рабочее время" — written by
    // `trySetLocalTimeProcessingSpeed` below.
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
    ///
    /// Phase 11.4: returns the created note's id (`nil` if the response
    /// shape is unexpected — treated as "couldn't determine the id", not a
    /// request failure, since the note itself was already created
    /// successfully by the time this parses the body) so
    /// `UploadOrchestrator`/`RecordingHistory` can persist it onto
    /// `RecordingEntry.kommoNoteId` for a later `editNote` call. Windows
    /// parity source: `KommoService.PostNoteAsync`'s `_embedded.notes[0].id`
    /// extraction.
    @discardableResult
    public static func addNote(crmUrl: String, text: String) async throws -> Int64? {
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

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let embedded = json["_embedded"] as? [String: Any],
              let notes = embedded["notes"] as? [[String: Any]],
              let first = notes.first,
              let noteId = (first["id"] as? NSNumber)?.int64Value
        else {
            return nil
        }
        return noteId
    }

    /// Phase 11.4 — Windows parity: `KommoService.EditNoteAsync`. Patches an
    /// already-created note's text in place (`PATCH /leads/{id}/notes`,
    /// keyed by the note's own `id` rather than `entity_id` the way
    /// `addNote`'s create payload is), then — same as `applyCallMetadata`'s
    /// legs, but sequential here rather than concurrent since both are
    /// best-effort follow-ups to a note edit the caller already knows
    /// succeeded, not independent legs racing each other — re-patches the
    /// call-type field and re-checks the Nedozvon auto-advance in case the
    /// user changed the call type while editing the report.
    ///
    /// Returns a `String?` warning (`nil` == success) rather than throwing,
    /// unlike `addNote` — mirrors Windows' `Task<string?>` shape, which
    /// `CallRecordingCoordinator.editReport` needs to aggregate alongside
    /// `TelegramUploadService`'s own edit outcome via `async let` without
    /// either leg's failure aborting the other.
    ///
    /// No `isKommoEnabled` short-circuit beyond the plain token-presence
    /// check below — deliberately different from `addNote`'s call site
    /// (`UploadOrchestrator.attemptKommo`, which does gate on
    /// `isKommoEnabled` per Phase 12, see `AppSettings.kommoSubdomain`'s
    /// doc comment). This edits a note that was already created while
    /// Kommo *was* enabled — if the user pauses the integration afterward
    /// but still edits the call report (`CallRecordingCoordinator
    /// .editReport`), the already-posted note should stay in sync rather
    /// than silently drift stale just because automation is paused now.
    public static func editNote(leadUrl: String, noteId: Int64, noteText: String, callType: String? = nil) async -> String? {
        guard let token = AppSettings.shared.kommoApiToken, !token.isEmpty else {
            return "Kommo: інтеграція вимкнена"
        }
        guard let (subdomain, leadId) = parseLeadURL(leadUrl) else {
            return "Kommo: не вдалося розпарсити URL ліда"
        }
        let baseURL = "https://\(subdomain).kommo.com/api/v4"

        guard let url = URL(string: "\(baseURL)/leads/\(leadId)/notes") else {
            return "Kommo: не вдалося розпарсити URL ліда"
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Windows parity: `PATCH /leads/{id}/notes` body is keyed by the
        // note's own `id` (not `entity_id`, which `addNote`'s create payload
        // above uses) — that's what tells Kommo which existing note to edit
        // rather than create a new one.
        let payload: [[String: Any]] = [[
            "id": noteId,
            "note_type": "common",
            "params": ["text": noteText],
        ]]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let bodyText = String(data: data, encoding: .utf8) ?? "<нечитабельно>"
                return "Kommo: помилка \(status): \(bodyText)"
            }
        } catch {
            return "Kommo: \(error)"
        }

        let trimmedCallType = callType?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedCallType, !trimmedCallType.isEmpty {
            await patchLeadField(baseURL: baseURL, token: token, leadId: leadId, fieldId: callTypeFieldId, value: trimmedCallType)
        }
        if let callType, callType.contains(noCommunicationCallTypeMarker) {
            await tryAdvanceToNedozvonStatus(baseURL: baseURL, token: token, leadId: leadId)
        }

        return nil
    }

    // MARK: - Phase 11.5 (missed-call reporting): client phone lookup

    /// Windows parity source: `KommoService.GetClientPhoneAsync` — used by
    /// `MissedCallReportViewModel.OpenMessengerAsync` to resolve the phone
    /// number behind a messenger deep link. Reuses `getLeadDetails`'s
    /// already-parsed `contactId`/`companyId` (see below) rather than a
    /// dedicated lookup call — same contact-first-then-company fallback
    /// order Windows uses. Returns `nil` (not an error) when Kommo isn't
    /// configured, the URL doesn't parse, or no phone is found anywhere —
    /// same opt-in-automation shape as `addNote`/`applyCallMetadata`.
    public static func getClientPhone(leadUrl: String) async -> String? {
        guard let token = AppSettings.shared.kommoApiToken, !token.isEmpty else {
            print("[KommoService] ⚠️ getClientPhone: Kommo не налаштовано (немає apiToken) — '\(leadUrl)'.")
            return nil
        }
        guard let (subdomain, leadId) = parseLeadURL(leadUrl) else {
            print("[KommoService] ⚠️ getClientPhone: не вдалося розпарсити URL ліда '\(leadUrl)'.")
            return nil
        }
        let baseURL = "https://\(subdomain).kommo.com/api/v4"

        let details = await getLeadDetails(baseURL: baseURL, token: token, leadId: leadId)
        print("[KommoService] ℹ️ getClientPhone: лід \(leadId) → contactId=\(details.contactId ?? "nil"), companyId=\(details.companyId ?? "nil").")

        var phone: String?
        if let contactId = details.contactId {
            phone = await getContactPhone(baseURL: baseURL, token: token, contactId: contactId)
        }
        if (phone?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true), let companyId = details.companyId {
            phone = await getCompanyPhone(baseURL: baseURL, token: token, companyId: companyId)
        }

        let trimmed = phone?.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed?.isEmpty ?? true {
            print("[KommoService] ❌ getClientPhone: телефон не знайдено ні в контакті, ні в компанії ліда \(leadId).")
        } else {
            print("[KommoService] ✅ getClientPhone: знайдено телефон '\(trimmed!)' для ліда \(leadId).")
        }
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
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
    ///
    /// Phase 15: now returns the two processing-speed values (previously
    /// discarded entirely) so `MissedCallDeliveryService` can cache them
    /// onto a `PendingMissedCall` for Google Sheets delivery — Windows
    /// parity: `ProcessLeadAsync`'s `(NoteId, ProcessingSpeedMinutes,
    /// ProcessingSpeedWorkMinutes)` tuple return (this method doesn't post
    /// the note itself, so only the two speed values carry over here).
    public static func applyCallMetadata(crmUrl: String, callStartTime: Date?, callType: String?) async -> (speedMinutes: Int?, speedWorkMinutes: Int?) {
        guard let token = AppSettings.shared.kommoApiToken, !token.isEmpty else { return (nil, nil) }
        guard let (subdomain, leadId) = parseLeadURL(crmUrl) else { return (nil, nil) }
        let baseURL = "https://\(subdomain).kommo.com/api/v4"

        async let dateTask = resolveProcessingSpeed(baseURL: baseURL, token: token, leadId: leadId, callStartTime: callStartTime)
        async let callTypeTask: Void = applyCallTypeField(baseURL: baseURL, token: token, leadId: leadId, callType: callType)
        async let statusTask: Void = maybeAdvanceNedozvonStatus(baseURL: baseURL, token: token, leadId: leadId, callType: callType)

        let speeds = await dateTask
        await callTypeTask
        await statusTask
        return speeds
    }

    /// Windows parity source: `KommoService.RecalculateProcessingSpeedAsync`
    /// — a lightweight variant of `applyCallMetadata` used purely to
    /// backfill the two speed values when Kommo already succeeded earlier
    /// but they came back `nil` (e.g. the lead's contact/company wasn't
    /// linked yet at that time). Skips the note/call-type/Nedozvon-status
    /// legs entirely — just re-derives the speed fields via the same
    /// `trySetFirstContactDate` path.
    public static func recalculateProcessingSpeed(crmUrl: String, callStartTime: Date?) async -> (speedMinutes: Int?, speedWorkMinutes: Int?) {
        guard let token = AppSettings.shared.kommoApiToken, !token.isEmpty else { return (nil, nil) }
        guard let (subdomain, leadId) = parseLeadURL(crmUrl) else { return (nil, nil) }
        guard let callStartTime else { return (nil, nil) }
        let baseURL = "https://\(subdomain).kommo.com/api/v4"
        return await trySetFirstContactDate(baseURL: baseURL, token: token, leadId: leadId, callStartTime: callStartTime)
    }

    private static func resolveProcessingSpeed(baseURL: String, token: String, leadId: String, callStartTime: Date?) async -> (speedMinutes: Int?, speedWorkMinutes: Int?) {
        guard let callStartTime else { return (nil, nil) }
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
    /// including the phone/timezone-derived "робочий час" leg
    /// (`processingSpeedLocalTimeFieldId`, delegated to
    /// `trySetLocalTimeProcessingSpeed` below) added in Phase 10.1c.
    ///
    /// Never overwrites a field that already has *any* non-empty value
    /// (`firstContactOccupied`/`speedMinutesOccupied`/
    /// `speedWorkMinutesOccupied` below) — someone may have filled it in by
    /// hand in Kommo's UI already.
    private static func trySetFirstContactDate(baseURL: String, token: String, leadId: String, callStartTime: Date) async -> (speedMinutes: Int?, speedWorkMinutes: Int?) {
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
        // замість розрахунку (для обох полів швидкості), з тим самим "не
        // чіпаємо, якщо вже зайняте" захистом.
        if details.isReactivationSource {
            if !details.speedMinutesOccupied {
                await patchLeadField(baseURL: baseURL, token: token, leadId: leadId, fieldId: processingSpeedFieldId, value: 0)
            }
            if !details.speedWorkMinutesOccupied {
                await patchLeadField(baseURL: baseURL, token: token, leadId: leadId, fieldId: processingSpeedLocalTimeFieldId, value: 0)
            }
            let minutes = details.speedMinutesOccupied ? details.speedMinutes : 0
            let workMinutes = details.speedWorkMinutesOccupied ? details.speedWorkMinutes : 0
            return (minutes, workMinutes)
        }

        guard let createdAt = details.createdAt, let firstContactUnix else {
            let minutes = details.speedMinutesOccupied ? details.speedMinutes : nil
            let workMinutes = details.speedWorkMinutesOccupied ? details.speedWorkMinutes : nil
            return (minutes, workMinutes)
        }

        let minutes: Int?
        if details.speedMinutesOccupied {
            minutes = details.speedMinutes
        } else {
            let computed = Int((Double(abs(createdAt - firstContactUnix)) / 60).rounded())
            await patchLeadField(baseURL: baseURL, token: token, leadId: leadId, fieldId: processingSpeedFieldId, value: computed)
            minutes = computed
        }

        let workMinutes: Int?
        if details.speedWorkMinutesOccupied {
            // Already set — leave it, matching Windows' "keep whatever's there" branch.
            workMinutes = details.speedWorkMinutes
        } else if details.contactId != nil || details.companyId != nil {
            workMinutes = await trySetLocalTimeProcessingSpeed(
                baseURL: baseURL, token: token, leadId: leadId,
                contactId: details.contactId, companyId: details.companyId,
                leadCreatedAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                firstContactAt: Date(timeIntervalSince1970: TimeInterval(firstContactUnix))
            )
        } else {
            print("[KommoService] ⚠️ лід \(leadId) без прив'язаного контакту чи компанії — поле 'робочий час' не заповнено.")
            workMinutes = nil
        }

        return (minutes, workMinutes)
    }

    /// Windows parity source: `KommoService.TrySetLocalTimeProcessingSpeedAsync`.
    /// Resolves a timezone from the lead's contact (falling back to its
    /// company) phone number, then sums how much of `[leadCreatedAt,
    /// firstContactAt]` falls inside the configured workday window
    /// (`AppSettings.shared.workDayStartMinutes/EndMinutes`) in that local
    /// time — same "робочий час" definition as Windows'
    /// `CalculateWorkingHoursDuration`.
    private static func trySetLocalTimeProcessingSpeed(
        baseURL: String, token: String, leadId: String,
        contactId: String?, companyId: String?,
        leadCreatedAt: Date, firstContactAt: Date
    ) async -> Int? {
        var phone: String?
        if let contactId {
            phone = await getContactPhone(baseURL: baseURL, token: token, contactId: contactId)
        }
        if (phone?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true), let companyId {
            phone = await getCompanyPhone(baseURL: baseURL, token: token, companyId: companyId)
        }
        guard let phone, !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("[KommoService] ⚠️ контакт \(contactId ?? "—") і компанія \(companyId ?? "—") (лід \(leadId)) без телефону — поле 'робочий час' не заповнено.")
            return nil
        }

        guard let (timeZone, isUkrainian) = resolveTimeZone(fromPhone: phone) else {
            print("[KommoService] ⚠️ не вдалося визначити часовий пояс за номером '\(phone)' (лід \(leadId)) — поле 'робочий час' не заповнено.")
            return nil
        }

        // Для українських номерів вікно робочого часу зсувається на +7 год
        // в обидва боки (напр. дефолт 9:00–21:00 → 16:00–04:00).
        var workDayStart = TimeInterval(AppSettings.shared.workDayStartMinutes * 60)
        var workDayEnd = TimeInterval(AppSettings.shared.workDayEndMinutes * 60)
        if isUkrainian {
            workDayStart += 7 * 3600
            workDayEnd += 7 * 3600
        }

        let leadCreatedLocal = localWallClockAsUTC(leadCreatedAt, timeZone: timeZone)
        let callStartLocal = localWallClockAsUTC(firstContactAt, timeZone: timeZone)

        let duration = calculateWorkingHoursDuration(
            startLocal: leadCreatedLocal, endLocal: callStartLocal, workDayStart: workDayStart, workDayEnd: workDayEnd)
        let minutes = Int((duration / 60).rounded())

        await patchLeadField(baseURL: baseURL, token: token, leadId: leadId, fieldId: processingSpeedLocalTimeFieldId, value: minutes)
        return minutes
    }

    /// Windows parity source: `KommoService.TryResolveTimeZoneFromPhone`.
    /// `PhoneNumberKit` (added to `Package.swift` Phase 10.1c) replaces
    /// libphonenumber-csharp for the parsing step; `NANPTimeZoneMapper`
    /// (Phase 10.1c revision) replaces its `PhoneNumberToTimeZonesMapper`
    /// geocoder for the actual zone lookup — same underlying libphonenumber
    /// geocoder data both sides ultimately read, not just a same-shaped
    /// re-implementation. Windows resolves a real geographic zone only for
    /// Ukrainian and US numbers — every other country (Canada included,
    /// since it has its own NANP region code distinct from "US") is treated
    /// as if the client were in Miami; that exact behavior is reproduced
    /// here rather than "improved", for parity with what production Kommo
    /// data already looks like.
    private static func resolveTimeZone(fromPhone rawPhone: String) -> (timeZone: TimeZone, isUkrainian: Bool)? {
        let utility = PhoneNumberUtility()
        let trimmed = rawPhone.trimmingCharacters(in: .whitespacesAndNewlines)

        let phoneNumber: PhoneNumber
        do {
            phoneNumber = try utility.parse(trimmed)
        } catch {
            guard !trimmed.hasPrefix("+") else { return nil }
            do {
                phoneNumber = trimmed.hasPrefix("0")
                    // Local Ukrainian national format with a trunk "0"
                    // (e.g. "0 (98) 721 26 42") — no country code, so parse
                    // with region "UA" instead of blindly prepending "+"
                    // (which would produce an invalid "+0..." number, since
                    // no country calling code starts with "0").
                    ? try utility.parse(trimmed, withRegion: "UA", ignoreType: true)
                    // No "+" but the digits already look like they include
                    // a country calling code — just missing the leading "+".
                    : try utility.parse("+" + trimmed)
            } catch {
                return nil
            }
        }

        let isUkrainian = phoneNumber.regionID == "UA"
        if isUkrainian {
            return (TimeZone(identifier: "Europe/Kyiv") ?? TimeZone(identifier: "Europe/Kiev")!, true)
        }

        if phoneNumber.regionID == "US" {
            // Full digit string (country calling code + national number,
            // e.g. "12125551234") — NANPTimeZoneMapper does its own
            // longest-prefix match over this, at up to 7-digit granularity,
            // not just the 3-digit area code the old table matched on.
            let fullDigits = "\(phoneNumber.countryCode)\(phoneNumber.nationalNumber)"
            if let tzId = NANPTimeZoneMapper.timeZone(forDigits: fullDigits), let tz = TimeZone(identifier: tzId) {
                return (tz, false)
            }
        }

        return (TimeZone(identifier: "America/New_York")!, false)
    }

    /// Re-labels a `Date`'s wall-clock fields *in `timeZone`* as if they
    /// were UTC — e.g. 14:00 America/Denver becomes a `Date` whose UTC
    /// components read 14:00. `calculateWorkingHoursDuration` below then
    /// does plain UTC `Date` arithmetic on the result, which is equivalent
    /// to Windows' naive `TimeSpan`/`DateTime` day-window math on a
    /// `TimeZoneInfo.ConvertTimeFromUtc`-converted (offset-less) `DateTime`
    /// — deliberately not DST-transition-aware in either port (a day that's
    /// actually 23 or 25 hours long is still treated as exactly 24).
    private static func localWallClockAsUTC(_ date: Date, timeZone: TimeZone) -> Date {
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = timeZone
        let components = localCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        return utcCalendar.date(from: components) ?? date
    }

    /// Windows parity source: `KommoService.CalculateWorkingHoursDuration` —
    /// sums only the portion of `[startLocal, endLocal]` (both already
    /// re-labeled onto UTC by `localWallClockAsUTC`) that falls within the
    /// daily `[workDayStart, workDayEnd)` window, walking one calendar day
    /// at a time and skipping the overnight gap each day — every day counts
    /// the same, no weekends excluded.
    private static func calculateWorkingHoursDuration(
        startLocal: Date, endLocal: Date, workDayStart: TimeInterval, workDayEnd: TimeInterval
    ) -> TimeInterval {
        var start = startLocal
        var end = endLocal
        if end < start { swap(&start, &end) }

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!

        var total: TimeInterval = 0
        var day = utcCalendar.startOfDay(for: start)
        let lastDay = utcCalendar.startOfDay(for: end)

        while day <= lastDay {
            let windowStart = day.addingTimeInterval(workDayStart)
            let windowEnd = day.addingTimeInterval(workDayEnd)
            let segmentStart = max(windowStart, start)
            let segmentEnd = min(windowEnd, end)
            if segmentEnd > segmentStart {
                total += segmentEnd.timeIntervalSince(segmentStart)
            }
            day = utcCalendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
        }
        return total
    }

    /// Windows parity source: `KommoService.GetContactPhoneAsync`.
    private static func getContactPhone(baseURL: String, token: String, contactId: String) async -> String? {
        await getEntityPhone(baseURL: baseURL, token: token, path: "contacts/\(contactId)")
    }

    /// Windows parity source: `KommoService.GetCompanyPhoneAsync` — fallback
    /// for when the contact itself has no phone but the lead's company does
    /// (e.g. the contact was created without one, but a form recorded the
    /// number on the company instead).
    private static func getCompanyPhone(baseURL: String, token: String, companyId: String) async -> String? {
        await getEntityPhone(baseURL: baseURL, token: token, path: "companies/\(companyId)")
    }

    // Shared by getContactPhone/getCompanyPhone — Kommo's "Телефон" field
    // (field_id = contactPhoneFieldId) is a multitext field on both entity
    // types with the same shape (possibly several entries of different
    // types — WORK/MOB/FAX/HOME/OTHER — some possibly empty), so both read
    // it identically; only the endpoint path differs.
    private static func getEntityPhone(baseURL: String, token: String, path: String) async -> String? {
        guard let url = URL(string: "\(baseURL)/\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("[KommoService] ❌ getEntityPhone(\(path)) HTTP \(status).")
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let fields = json["custom_fields_values"] as? [[String: Any]] else {
                print("[KommoService] ⚠️ getEntityPhone(\(path)): відповідь без custom_fields_values (об'єкт без жодного заповненого поля?).")
                return nil
            }

            for field in fields {
                guard let fieldId = (field["field_id"] as? NSNumber)?.int64Value, fieldId == contactPhoneFieldId else { continue }
                guard let values = field["values"] as? [[String: Any]] else { return nil }
                for v in values {
                    if let s = v["value"] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return s
                    }
                }
                print("[KommoService] ⚠️ getEntityPhone(\(path)): поле '\(contactPhoneFieldId)' знайдено, але всі його значення порожні.")
                return nil
            }
            // Шукане поле (contactPhoneFieldId, "Телефон") взагалі відсутнє
            // серед custom_fields_values цього контакту/компанії — або в
            // ньому справді немає жодного значення (Kommo не включає порожні
            // поля в цей масив), або (менш ймовірно, якщо це той самий
            // акаунт, що й Windows) захардкоджений field_id тут не збігається
            // з реальним "Телефон"-полем цього акаунту. Друкуємо всі наявні
            // field_id, щоб було видно, яке з них насправді є телефоном.
            let presentFieldIds = fields.compactMap { ($0["field_id"] as? NSNumber)?.int64Value }
            print("[KommoService] ❌ getEntityPhone(\(path)): поле '\(contactPhoneFieldId)' (очікуване 'Телефон') відсутнє серед заповнених полів. Наявні field_id: \(presentFieldIds).")
            return nil
        } catch {
            print("[KommoService] ❌ getEntityPhone(\(path)) виняток: \(error)")
            return nil
        }
    }

    private struct LeadDetails {
        var createdAt: Int64?
        var firstContactUnix: Int64?
        var firstContactOccupied = false
        var contactId: String?
        var companyId: String?
        var speedMinutes: Int?
        var speedMinutesOccupied = false
        var speedWorkMinutes: Int?
        var speedWorkMinutesOccupied = false
        var isReactivationSource = false
    }

    /// Windows parity source: `KommoService.GetLeadDetailsAsync`.
    /// `"with=contacts,companies,custom_fields"` is what threads
    /// `contactId`/`companyId` through to `trySetLocalTimeProcessingSpeed`.
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

                    guard fieldId == firstContactFieldId || fieldId == processingSpeedFieldId
                        || fieldId == processingSpeedLocalTimeFieldId else { continue }
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
                    } else if fieldId == processingSpeedFieldId {
                        details.speedMinutesOccupied = true
                        details.speedMinutes = numericValue.map(Int.init)
                    } else {
                        details.speedWorkMinutesOccupied = true
                        details.speedWorkMinutes = numericValue.map(Int.init)
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
