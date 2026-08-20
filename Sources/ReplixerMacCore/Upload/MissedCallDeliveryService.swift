import Foundation

/// Background delivery queue for missed-call reports — posts the Kommo note
/// (+ call metadata: first-contact date/processing speed/call-type/Nedozvon
/// status advance, via `KommoService.applyCallMetadata`) and, independently,
/// appends a row to the user's configured Google Sheet, for every submitted
/// `MissedCallReportData`, retrying on a 10s tick until both legs succeed.
/// Windows parity source: `Services/Upload/MissedCallDeliveryService.cs`'s
/// `DeliverAsync`.
///
/// Phase 15: the Sheets leg that used to be entirely absent here now mirrors
/// Windows almost exactly — `kommoDelivered`/`sheetDelivered` are tracked
/// independently on each `PendingMissedCall` (see that type's doc comment),
/// an entry only leaves the queue once Kommo is delivered AND (Sheets is
/// disabled/unconfigured OR Sheets is also delivered), and processing-speed
/// values computed by the Kommo leg are cached and threaded into the Sheets
/// row rather than being silently dropped.
///
/// Still not ported: Windows' `DeliveryStatusChanged` event — Mac keeps
/// using `MissedCallHistory.markKommoDelivered`/`markSheetDelivered`
/// posting `didChangeNotification` directly, same as before, since
/// `MissedCallsView` already observes that.
///
/// Otherwise mirrors `PendingUploadRetryService`'s exact ticker shape (plain
/// `Task` loop, 10s `Task.sleep`, no `Timer`/`Interlocked` reentrancy guard
/// needed) rather than Windows' `System.Threading.Timer`.
public final class MissedCallDeliveryService {
    public static let shared = MissedCallDeliveryService()

    private static let intervalNanoseconds: UInt64 = 10_000_000_000 // 10s, Windows-parity interval

    private static let store = JSONStore<[PendingMissedCall]>(url:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReplixerMac", isDirectory: true)
            .appendingPathComponent("pending_missed_calls.json")
    )

    private let lock = NSLock()
    private var _pending: [PendingMissedCall]
    // De-dup guard: a submit-triggered immediate attempt and the next 10s
    // tick could otherwise both pick up the same still-queued item — mirrors
    // Windows' `_inFlight` dictionary, just a Set here since there's nothing
    // per-item worth storing beyond "currently being attempted".
    private var inFlight: Set<UUID> = []
    private var task: Task<Void, Never>?

    private init() {
        switch MissedCallDeliveryService.store.load() {
        case .decoded(let loaded):
            _pending = loaded
        case .notFound:
            _pending = []
        case .decodeFailed(let error):
            print("[MissedCallDeliveryService] ❌ не вдалося прочитати \(MissedCallDeliveryService.store.url.path): \(error)")
            print("[MissedCallDeliveryService] ⚠️ Стартую з порожньою чергою — файл на диску поки НЕ буде перезаписано.")
            _pending = []
        }
    }

    public func start() {
        guard task == nil else { return } // already running
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: MissedCallDeliveryService.intervalNanoseconds)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                await self.tick()
            }
        }
        print("[MissedCallDeliveryService] 🔁 фоновий сервіс доставки пропущених дзвінків запущено (кожні 10с)")
    }

    /// Call before process exit — same reasoning as
    /// `PendingUploadRetryService.stop()`.
    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Enqueues a submitted report for delivery and immediately attempts it
    /// once (Windows parity: `SubmitAsync`'s "add, save, then try right
    /// away" ordering) — the 10s tick only exists to catch attempts that
    /// fail this first try (network hiccup, Kommo/Sheets not reachable yet,
    /// etc.).
    public func submit(id: UUID, data: MissedCallReportData) {
        let item = PendingMissedCall(
            id: id,
            crmUrl: data.crmUrl,
            note: data.formatCaption(),
            callType: data.callType,
            missedAt: data.firstContactTime,
            manager: data.manager,
            screenshotUrlsByMessenger: data.screenshotUrlsByMessenger
        )
        lock.lock()
        _pending.append(item)
        let snapshot = _pending
        lock.unlock()
        MissedCallDeliveryService.store.scheduleSave(snapshot)

        Task { await attemptDelivery(item, isFirstAttempt: true) }
    }

    // Swift 6: `NSLock.lock()`/`unlock()` are unavailable to call directly
    // from inside an `async` function body ("use async-safe scoped locking
    // instead"). `tick`/`attemptDelivery` below are both `async`, so their
    // locking is routed through these plain (non-`async`) helpers instead —
    // same fix shape, same reasoning as everywhere else in this codebase
    // that pairs an `NSLock` with `async` callers (e.g. `RecordingHistory`,
    // which never touches `lock` directly from an `async func` either).
    private func snapshotPending() -> [PendingMissedCall] {
        lock.lock()
        defer { lock.unlock() }
        return _pending
    }

    private func beginInFlight(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !inFlight.contains(id) else { return false }
        inFlight.insert(id)
        return true
    }

    private func endInFlight(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        inFlight.remove(id)
    }

    private func tick() async {
        let snapshot = snapshotPending()
        for item in snapshot {
            await attemptDelivery(item, isFirstAttempt: false)
        }
    }

    /// Windows parity source: `DeliverAsync`. `isFirstAttempt` only gates
    /// whether a failure gets reported via `ErrorReporter` (same "don't spam
    /// the developer chat on every 10s retry, only the first time" reasoning
    /// as Windows' own `isFirstAttempt` check).
    private func attemptDelivery(_ item: PendingMissedCall, isFirstAttempt: Bool) async {
        guard beginInFlight(item.id) else { return }
        defer { endInFlight(item.id) }

        var kommoOk = item.kommoDelivered
        var speedMinutes = item.processingSpeedMinutes
        var speedWorkMinutes = item.processingSpeedWorkMinutes

        if !kommoOk {
            // Same "not configured/not enabled" opt-in-automation shape as
            // UploadOrchestrator.attemptKommo (Phase 12: isKommoEnabled
            // gates this too, not just presence of subdomain/token) — stays
            // queued until Kommo gets configured and switched on.
            guard AppSettings.shared.kommoSubdomain != nil, AppSettings.shared.kommoApiToken != nil, AppSettings.shared.isKommoEnabled else {
                return
            }
            do {
                let noteId = try await KommoService.addNote(crmUrl: item.crmUrl, text: item.note)
                guard noteId != nil else {
                    print("[MissedCallDeliveryService] ❌ Kommo не повернув id нотатки для пропущеного дзвінка \(item.id) — лишаю в черзі.")
                    if isFirstAttempt {
                        await ErrorReporter.shared.report(category: "MISSED_CALL", message: "Не вдалося зафіксувати недодзвон у Kommo (немає id нотатки). Спробуємо ще раз у фоні.")
                    }
                    return
                }
                let speeds = await KommoService.applyCallMetadata(crmUrl: item.crmUrl, callStartTime: item.missedAt, callType: item.callType)
                speedMinutes = speeds.speedMinutes
                speedWorkMinutes = speeds.speedWorkMinutes
                kommoOk = true
                MissedCallHistory.shared.markKommoDelivered(id: item.id)
            } catch {
                print("[MissedCallDeliveryService] ❌ не вдалося додати нотатку в Kommo для пропущеного дзвінка \(item.id): \(error)")
                if isFirstAttempt {
                    await ErrorReporter.shared.report(category: "MISSED_CALL", message: "Не вдалося зафіксувати недодзвон у Kommo. Спробуємо ще раз у фоні.", error: error)
                }
                return
            }
        }

        let needSheet = AppSettings.shared.isGoogleSheetsEnabled
            && !(AppSettings.shared.googleSheetsId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        var sheetOk = item.sheetDelivered || !needSheet

        // Backfill: Kommo succeeded (now or on an earlier attempt) but at
        // least one speed value is still missing (e.g. the lead's
        // contact/company wasn't linked yet when the note first posted) —
        // re-derive just the speed fields via the lighter recalculate path
        // before building the Sheets row, same as Windows'
        // `RecalculateProcessingSpeedAsync` call.
        if kommoOk, needSheet, !item.sheetDelivered, speedMinutes == nil || speedWorkMinutes == nil {
            let recalculated = await KommoService.recalculateProcessingSpeed(crmUrl: item.crmUrl, callStartTime: item.missedAt)
            speedMinutes = speedMinutes ?? recalculated.speedMinutes
            speedWorkMinutes = speedWorkMinutes ?? recalculated.speedWorkMinutes
        }

        var sheetWarning: String?
        if kommoOk, needSheet, !item.sheetDelivered {
            let row = Self.buildSheetRow(
                manager: item.manager, callType: item.callType, missedAt: item.missedAt,
                speedMinutes: speedMinutes, speedWorkMinutes: speedWorkMinutes,
                crmUrl: item.crmUrl, screenshotUrlsByMessenger: item.screenshotUrlsByMessenger
            )
            let result = await GoogleSheetsUploadService.appendRow(
                spreadsheetId: AppSettings.shared.googleSheetsId ?? "",
                sheetName: AppSettings.shared.googleSheetsTabName ?? "",
                values: row
            )
            sheetOk = result.success
            sheetWarning = result.error
            if sheetOk {
                MissedCallHistory.shared.markSheetDelivered(id: item.id)
            } else {
                print("[MissedCallDeliveryService] ⚠️ не вдалося продублювати пропущений дзвінок \(item.id) у Google Таблицю: \(sheetWarning ?? "невідома помилка").")
                if isFirstAttempt {
                    await ErrorReporter.shared.report(category: "MISSED_CALL_SHEET", message: "Недодзвон зафіксовано в Kommo, але не вдалося продублювати в Google Таблицю. Спробуємо ще раз у фоні.\n\(sheetWarning ?? "")")
                }
            }
        }

        if kommoOk && sheetOk {
            removeFromQueue(item.id)
            print("[MissedCallDeliveryService] ✅ пропущений дзвінок \(item.id) повністю доставлено (Kommo\(needSheet ? " + Google Таблиця" : "")).")
            // Windows parity: `MissedCallDeliveryService.cs:161`.
            if isFirstAttempt {
                NotificationService.showSuccess("Недодзвон успішно зафіксовано.")
            } else {
                NotificationService.showSuccess("Недодзвон, який раніше не вдалося зафіксувати, тепер успішно доставлено.")
            }
        } else {
            var updated = item
            updated.kommoDelivered = kommoOk
            updated.sheetDelivered = sheetOk
            updated.processingSpeedMinutes = speedMinutes
            updated.processingSpeedWorkMinutes = speedWorkMinutes
            replaceInQueue(updated)
        }
    }

    private func removeFromQueue(_ id: UUID) {
        lock.lock()
        _pending.removeAll { $0.id == id }
        let snapshot = _pending
        lock.unlock()
        MissedCallDeliveryService.store.scheduleSave(snapshot)
    }

    private func replaceInQueue(_ updated: PendingMissedCall) {
        lock.lock()
        if let index = _pending.firstIndex(where: { $0.id == updated.id }) {
            _pending[index] = updated
        }
        let snapshot = _pending
        lock.unlock()
        MissedCallDeliveryService.store.scheduleSave(snapshot)
    }

    // MARK: - Sheets row building (Windows parity: BuildSheetRow)

    private static let ukrainianMonths = [
        "Січень", "Лютий", "Березень", "Квітень", "Травень", "Червень",
        "Липень", "Серпень", "Вересень", "Жовтень", "Листопад", "Грудень"
    ]

    /// Windows parity source: `MissedCallDeliveryService.BuildSheetRow` —
    /// same column order as `GoogleSheetsUploadService.sheetHeaders`. Uses
    /// `Date()` (now) for the "Рік"/"День"/"Місяць"/"Час запису" columns —
    /// same as Windows' `DateTime.Now` there, i.e. the moment the row is
    /// written, not `missedAt`. The Ukrainian month name is nominative case
    /// (a hardcoded array), NOT the standard `uk_UA` locale's genitive-case
    /// month name — matching Windows' own `UkrainianMonths` array exactly
    /// rather than "correcting" it to a locale-provided name.
    private static func buildSheetRow(
        manager: String, callType: String?, missedAt: Date,
        speedMinutes: Int?, speedWorkMinutes: Int?, crmUrl: String,
        screenshotUrlsByMessenger: [String: String]
    ) -> [Any?] {
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let year = calendar.component(.year, from: now)
        let day = calendar.component(.day, from: now)
        let month = calendar.component(.month, from: now)
        let monthName = ukrainianMonths[month - 1]

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "HH:mm:ss"
        let timeString = timeFormatter.string(from: now)

        let missedAtFormatter = DateFormatter()
        missedAtFormatter.locale = Locale(identifier: "en_US_POSIX")
        missedAtFormatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
        let missedAtString = missedAtFormatter.string(from: missedAt)

        var row: [Any?] = [
            year, day, monthName, timeString, manager, callType ?? "",
            missedAtString, speedMinutes, speedWorkMinutes, crmUrl
        ]
        for messenger in MessengerDeepLinkProvider.supportedMessengers {
            let url = screenshotUrlsByMessenger[messenger]?.trimmingCharacters(in: .whitespacesAndNewlines)
            row.append((url?.isEmpty ?? true) ? nil : url)
        }
        return row
    }

    /// Forces any pending debounced save to happen immediately — call
    /// before process exit, same reasoning as `RecordingHistory.flush()`.
    public func flush() {
        lock.lock()
        let snapshot = _pending
        lock.unlock()
        MissedCallDeliveryService.store.saveNow(snapshot)
    }
}
