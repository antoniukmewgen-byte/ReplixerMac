import Foundation

/// Background delivery queue for missed-call reports — posts the Kommo note
/// (+ call metadata: first-contact date/processing speed/call-type/Nedozvon
/// status advance, via `KommoService.applyCallMetadata`) for every submitted
/// `MissedCallReportData`, retrying on a 10s tick until it succeeds. Windows
/// parity source: `Services/Upload/MissedCallDeliveryService.cs`, scoped
/// down to a **Kommo-only** leg:
///
/// - No Google Sheets leg (`BuildSheetRow`/`RecalculateProcessingSpeedAsync`)
///   — mac has no Sheets integration at all yet (same gap already tracked
///   for recordings, see project status notes); an entry here is considered
///   fully delivered once the Kommo note succeeds, not "Kommo AND Sheets"
///   like Windows.
/// - No `DeliveryStatusChanged` event — `MissedCallHistory
///   .markKommoDelivered` posts `didChangeNotification` itself, which
///   `MissedCallsView` already observes the same way `RecordingsView`
///   observes `RecordingHistory`.
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
    /// fail this first try (network hiccup, Kommo not reachable yet, etc.).
    public func submit(id: UUID, data: MissedCallReportData) {
        let item = PendingMissedCall(
            id: id,
            crmUrl: data.crmUrl,
            note: data.formatCaption(),
            callType: data.callType,
            missedAt: data.firstContactTime,
            manager: data.manager
        )
        lock.lock()
        _pending.append(item)
        let snapshot = _pending
        lock.unlock()
        MissedCallDeliveryService.store.scheduleSave(snapshot)

        Task { await attemptDelivery(item) }
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
            await attemptDelivery(item)
        }
    }

    private func attemptDelivery(_ item: PendingMissedCall) async {
        guard beginInFlight(item.id) else { return }
        defer { endInFlight(item.id) }

        // Same "not configured/not enabled" opt-in-automation shape as
        // UploadOrchestrator.attemptKommo (Phase 12: isKommoEnabled gates
        // this too, not just presence of subdomain/token) — but here
        // there's nothing else this entry could deliver to, so staying
        // queued is the only outcome until Kommo gets configured and
        // switched on (or forever, if it never is — same accepted gap as a
        // recording whose Kommo note never posts).
        guard AppSettings.shared.kommoSubdomain != nil, AppSettings.shared.kommoApiToken != nil, AppSettings.shared.isKommoEnabled else { return }

        let noteId: Int64?
        do {
            noteId = try await KommoService.addNote(crmUrl: item.crmUrl, text: item.note)
        } catch {
            print("[MissedCallDeliveryService] ❌ не вдалося додати нотатку в Kommo для пропущеного дзвінка \(item.id): \(error)")
            return
        }
        guard noteId != nil else {
            print("[MissedCallDeliveryService] ❌ Kommo не повернув id нотатки для пропущеного дзвінка \(item.id) — лишаю в черзі.")
            return
        }

        await KommoService.applyCallMetadata(crmUrl: item.crmUrl, callStartTime: item.missedAt, callType: item.callType)

        MissedCallHistory.shared.markKommoDelivered(id: item.id)
        removeFromQueue(item.id)
        print("[MissedCallDeliveryService] ✅ пропущений дзвінок \(item.id) доставлено в Kommo.")
    }

    private func removeFromQueue(_ id: UUID) {
        lock.lock()
        _pending.removeAll { $0.id == id }
        let snapshot = _pending
        lock.unlock()
        MissedCallDeliveryService.store.scheduleSave(snapshot)
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
