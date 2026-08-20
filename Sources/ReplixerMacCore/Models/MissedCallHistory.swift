import Foundation

/// In-memory + persisted (`missed_calls.json`) history of missed-call
/// reports. Mirrors `RecordingHistory`'s exact shape (lock-protected
/// `_entries`, `mutate(_:)` funnel, `didChangeNotification`) — see that
/// type's doc comment for the full reasoning on why a plain `NSLock` is
/// enough here rather than an actor. Windows parity: this is the permanent
/// record `MissedCallsViewModel` reads for its list, distinct from
/// `MissedCallDeliveryService`'s `pending_missed_calls.json` queue (which
/// only tracks in-flight delivery attempts, not the full history — same
/// split as `RecordingHistory` vs. `PendingUploadRetryService`).
public final class MissedCallHistory {
    public static let shared = MissedCallHistory()

    public static let store = JSONStore<[MissedCallEntry]>(url:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReplixerMac", isDirectory: true)
            .appendingPathComponent("missed_calls.json")
    )

    public static let didChangeNotification = Notification.Name("ReplixerMac.MissedCallHistory.didChange")

    private let lock = NSLock()
    private var _entries: [MissedCallEntry]

    /// Thread-safe snapshot — same "copy out under the lock" contract as
    /// `RecordingHistory.entries`.
    public var entries: [MissedCallEntry] {
        lock.lock()
        defer { lock.unlock() }
        return _entries
    }

    private init() {
        switch MissedCallHistory.store.load() {
        case .decoded(let loaded):
            _entries = loaded
        case .notFound:
            _entries = []
        case .decodeFailed(let error):
            print("[MissedCallHistory] ❌ не вдалося прочитати \(MissedCallHistory.store.url.path): \(error)")
            print("[MissedCallHistory] ⚠️ Стартую з порожньою історією в пам'яті — файл на диску поки НЕ буде перезаписано, але зверни увагу, якщо це неочікувано.")
            _entries = []
        }
    }

    private func mutate(_ body: (inout [MissedCallEntry]) -> Bool) {
        let didChange: Bool
        let snapshot: [MissedCallEntry]
        lock.lock()
        didChange = body(&_entries)
        snapshot = _entries
        lock.unlock()
        guard didChange else { return }
        MissedCallHistory.store.scheduleSave(snapshot)
        NotificationCenter.default.post(name: MissedCallHistory.didChangeNotification, object: nil)
    }

    /// Records a freshly-submitted missed-call report. Called right after
    /// `MissedCallReportRequestStore` resolves with `.submitted`, before
    /// handing the same data off to `MissedCallDeliveryService.submit` —
    /// same "history entry exists immediately, delivery catches up
    /// asynchronously" ordering as `RecordingHistory.addStarted` /
    /// `UploadOrchestrator`.
    @discardableResult
    public func add(_ data: MissedCallReportData) -> UUID {
        let entry = MissedCallEntry(
            manager: data.manager,
            callType: data.callType,
            missedAt: data.firstContactTime,
            crmUrl: data.crmUrl,
            screenshotUrls: data.screenshotUrls
        )
        mutate { entries in
            entries.insert(entry, at: 0)
            return true
        }
        return entry.id
    }

    /// Flips `kommoDelivered` once `MissedCallDeliveryService` confirms the
    /// Kommo note was posted — drives `MissedCallEntry.statusText`.
    public func markKommoDelivered(id: UUID) {
        mutate { entries in
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
            guard !entries[index].kommoDelivered else { return false }
            entries[index].kommoDelivered = true
            return true
        }
    }

    /// Phase 15: flips `sheetDelivered` once `MissedCallDeliveryService`
    /// confirms the row was appended to the configured Google Sheet — mirrors
    /// `markKommoDelivered` exactly, just for the independent Sheets leg.
    /// Does NOT affect `statusText` (see `MissedCallEntry.sheetDelivered`'s
    /// doc comment) — this is tracking-only, same as Windows.
    public func markSheetDelivered(id: UUID) {
        mutate { entries in
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
            guard !entries[index].sheetDelivered else { return false }
            entries[index].sheetDelivered = true
            return true
        }
    }

    /// Forces any pending debounced save to happen immediately — call
    /// before process exit, same reasoning as `RecordingHistory.flush()`.
    public func flush() {
        MissedCallHistory.store.saveNow(entries)
    }
}
